#!/usr/bin/env python3
"""Extract an address map from Verilator VCD ADDR_RANGES[] constants.

Example:
    ./vcd_memory_map.py verilator_tb.vcd

The script looks for a scope whose name contains ``i_isolde_data_router``
and for variables named ``ADDR_RANGES[N]``.  Each range is expected to be a
64-bit packed value ``{start_addr[31:0], end_addr[31:0]}``.

Friendly names are inferred, when possible, from constants elsewhere in the
VCD such as DMEM_ADDR + DMEM_SIZE, MMIO_ADDR + MMIO_ADDR_END, or aggregate
per-tile windows such as SPM_NARROW_ADDR_BASE + N_REDMULE_TILES *
SPM_NARROW_SIZE.
"""

from __future__ import annotations

import argparse
import gzip
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple


VAR_RE = re.compile(
    r"^\s*\$var\s+\S+\s+(\d+)\s+(\S+)\s+(\S+)(?:\s+\[[^]]+\])?\s+\$end\s*$"
)
RANGE_NAME_RE = re.compile(r"^ADDR_RANGES\[(\d+)\]$")
VECTOR_RE = re.compile(r"^b([01xXzZ]+)\s+(\S+)\s*$")
SCALAR_RE = re.compile(r"^([01xXzZ])(\S+)\s*$")


@dataclass(frozen=True)
class Var:
    width: int
    code: str
    name: str
    scope: str

    @property
    def fullname(self) -> str:
        return f"{self.scope}.{self.name}" if self.scope else self.name


def open_text(path: Path):
    if path.suffix == ".gz":
        return gzip.open(path, "rt", encoding="utf-8", errors="replace")
    return path.open("rt", encoding="utf-8", errors="replace")


def parse_header(path: Path) -> Tuple[List[Var], int]:
    """Return VCD variables and line number immediately after $enddefinitions."""
    vars_: List[Var] = []
    scopes: List[str] = []

    with open_text(path) as f:
        for lineno, line in enumerate(f, 1):
            s = line.strip()

            if s.startswith("$scope "):
                # $scope module NAME $end
                parts = s.split()
                if len(parts) >= 4:
                    scopes.append(parts[2])
                continue

            if s.startswith("$upscope"):
                if scopes:
                    scopes.pop()
                continue

            m = VAR_RE.match(line)
            if m:
                width, code, name = m.groups()
                vars_.append(Var(int(width), code, name, ".".join(scopes)))
                continue

            if s.startswith("$enddefinitions"):
                return vars_, lineno

    raise ValueError("VCD has no $enddefinitions section")


def read_first_values(path: Path, wanted_codes: Iterable[str]) -> Dict[str, int]:
    """Read the first fully-known value assigned to each requested VCD id code."""
    wanted = set(wanted_codes)
    values: Dict[str, int] = {}

    if not wanted:
        return values

    with open_text(path) as f:
        for line in f:
            if len(values) == len(wanted):
                break

            m = VECTOR_RE.match(line.strip())
            if m:
                bits, code = m.groups()
                if code in wanted and code not in values and not re.search(r"[xXzZ]", bits):
                    values[code] = int(bits, 2)
                continue

            m = SCALAR_RE.match(line.strip())
            if m:
                bit, code = m.groups()
                if code in wanted and code not in values and bit in "01":
                    values[code] = int(bit)

    return values


def basename(name: str) -> str:
    """Strip only a trailing packed/unpacked index from a signal name."""
    return re.sub(r"\[[^]]+\]$", "", name)


def infer_named_regions(vars_: List[Var], values: Dict[str, int]) -> Dict[Tuple[int, int], str]:
    """Build {(start, end): LABEL} from address/size/count constants.

    Recognized forms include::

        NAME_ADDR + NAME_ADDR_END
        NAME_ADDR + NAME_SIZE
        NAME_ADDR_BASE + COUNT * NAME_SIZE

    The last form is useful for aggregate windows composed of several equal
    per-instance regions, e.g.::

        SPM_NARROW_ADDR_BASE + N_REDMULE_TILES * SPM_NARROW_SIZE
    """
    # Prefer package-ish constants, but accept any uniquely named constant in the VCD.
    named_values: Dict[str, List[int]] = {}
    for var in vars_:
        if var.code not in values or var.width > 64:
            continue
        name = basename(var.name)
        named_values.setdefault(name, []).append(values[var.code])

    # Keep only names whose aliases agree on one value.
    const: Dict[str, int] = {}
    for name, vals in named_values.items():
        uniq = set(vals)
        if len(uniq) == 1:
            const[name] = next(iter(uniq))

    regions: Dict[Tuple[int, int], str] = {}

    # Strongest form: NAME_ADDR + NAME_ADDR_END
    for name, start in const.items():
        if not name.endswith("_ADDR"):
            continue
        label = name[:-5]
        end_name = f"{label}_ADDR_END"
        if end_name in const:
            regions[(start, const[end_name])] = label

    # Second form: NAME_ADDR + NAME_SIZE
    for name, start in const.items():
        if not name.endswith("_ADDR"):
            continue
        label = name[:-5]
        size_name = f"{label}_SIZE"
        if size_name in const:
            key = (start, start + const[size_name])
            regions.setdefault(key, label)

    # Third form: NAME_ADDR_BASE + COUNT * NAME_SIZE.
    #
    # COUNT is intentionally restricted to constants whose names look like
    # instance/tile counts.  The resulting range still has to match an actual
    # ADDR_RANGES[] entry before the inferred label is ever printed, which
    # makes this heuristic conservative in practice.
    count_name_re = re.compile(
        r"^(?:N|NUM)_[A-Z0-9_]*(?:TILE|TILES|BANK|BANKS|CORE|CORES|PORT|PORTS|INSTANCE|INSTANCES)$"
    )
    counts = {
        name: value
        for name, value in const.items()
        if count_name_re.match(name) and 1 <= value <= 4096
    }

    for name, start in const.items():
        if not name.endswith("_ADDR_BASE"):
            continue
        label = name[:-10]
        size_name = f"{label}_SIZE"
        size = const.get(size_name)
        if not size:
            continue

        for count in counts.values():
            key = (start, start + count * size)
            regions.setdefault(key, label)

    return regions


def extract_ranges(path: Path, router_substr: str) -> List[Tuple[int, int, int, str]]:
    vars_, _ = parse_header(path)

    range_vars: List[Tuple[int, Var]] = []
    for var in vars_:
        m = RANGE_NAME_RE.match(var.name)
        if m and router_substr in var.scope:
            range_vars.append((int(m.group(1)), var))

    if not range_vars:
        candidates = [v.fullname for v in vars_ if RANGE_NAME_RE.match(v.name)]
        detail = ""
        if candidates:
            detail = "\nAvailable ADDR_RANGES variables:\n  " + "\n  ".join(candidates[:32])
        raise ValueError(
            f"No ADDR_RANGES[N] variables found under a scope containing {router_substr!r}."
            + detail
        )

    # All simple constants used for name inference, plus the range values themselves.
    count_name_re = re.compile(
        r"^(?:N|NUM)_[A-Z0-9_]*(?:TILE|TILES|BANK|BANKS|CORE|CORES|PORT|PORTS|INSTANCE|INSTANCES)$"
    )
    interesting_vars = [
        v for v in vars_
        if RANGE_NAME_RE.match(v.name)
        or v.name.endswith("_ADDR")
        or v.name.endswith("_ADDR_END")
        or v.name.endswith("_ADDR_BASE")
        or v.name.endswith("_SIZE")
        or count_name_re.match(v.name)
    ]
    values = read_first_values(path, (v.code for v in interesting_vars))
    named_regions = infer_named_regions(interesting_vars, values)

    result: List[Tuple[int, int, int, str]] = []
    for idx, var in sorted(range_vars):
        if var.width != 64:
            raise ValueError(f"{var.fullname} has width {var.width}; expected 64")
        if var.code not in values:
            raise ValueError(f"No known value found for {var.fullname} (VCD id {var.code!r})")

        packed = values[var.code]
        start = (packed >> 32) & 0xFFFF_FFFF
        end = packed & 0xFFFF_FFFF
        label = named_regions.get((start, end), "...")
        result.append((idx, start, end, label))

    return result


def main() -> int:
    ap = argparse.ArgumentParser(description="Extract ADDR_RANGES[] memory map from a VCD")
    ap.add_argument("vcd", type=Path, help="VCD file (plain .vcd or .vcd.gz)")
    ap.add_argument(
        "--router",
        default="i_isolde_data_router",
        help="substring identifying the router scope (default: %(default)s)",
    )
    ap.add_argument(
        "--no-names",
        action="store_true",
        help="do not infer DMEM/MMIO/etc. names",
    )
    args = ap.parse_args()

    try:
        ranges = extract_ranges(args.vcd, args.router)
    except (OSError, ValueError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    for idx, start, end, label in ranges:
        if args.no_names:
            print(f"[{idx}] 0x{start:08x} .. 0x{end:08x}")
        else:
            print(f"[{idx}] {label:<10}   0x{start:08x} .. 0x{end:08x}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())