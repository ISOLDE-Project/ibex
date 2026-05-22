#!/usr/bin/env python3
"""
flist2questa.py
===============
Convert a Verilator-generated .flist / .vc file into a QuestaSim-compatible
flist suitable for consumption by  qrun / vlog.

Transformations applied
-----------------------
DROP  – lines that are Verilator-only and have no Questa equivalent
XLAT  – lines that need syntax translation
DEDUP – duplicate file/incdir entries are removed (keeps first occurrence)
PASS  – lines that are already valid for Questa (+incdir+, +define+, .sv, .v)

Usage
-----
  python flist2questa.py  input.flist  output.flist  [--anchor /abs/build/dir]

  --anchor DIR   When set, all relative paths in the flist are resolved
                 relative to DIR and written as absolute paths.
                 Default: leave paths as-is.
"""

import sys
import os
import re
import argparse
from pathlib import Path

# ---------------------------------------------------------------------------
# Rules
# ---------------------------------------------------------------------------

# 1. Lines whose FIRST TOKEN starts with any of these prefixes are dropped.
DROP_PREFIXES = (
    # Verilator binary/mode flags
    "--Mdir",
    "--cc",
    "--sc",
    "--exe",
    "--main",
    "--build",
    "--trace",
    "--no-timing",
    "--timing",
    "--assert",
    "--unroll-count",
    "--top-module",   # Questa uses -top on the command line, not in the flist
    # Verilator C++ integration flags (entire line, value may follow on same line)
    "-CFLAGS",
    "-LDFLAGS",
    # Verilator warning flags
    "-Wall",
    "-Wno-",
    "-Wwarn-",
    # Verilator lint / waiver files  (.vlt)
    # handled separately below by extension check
)

# 2. Verilator .vlt waiver files – always drop
VLT_EXTENSION = ".vlt"

# 3. Translate  -G<PARAM>=<VALUE>  →  -g<PARAM>=<VALUE>
#    Verilator uses -G for generic override; Questa/vlog uses -g
GENERIC_RE = re.compile(r"^-G(\w+)=(.*)$")

# 4. Translate  -D<DEFINE>[=<VALUE>]  →  +define+<DEFINE>[=<VALUE>]
#    Verilator accepts -DFOO or -DFOO=BAR on the flist
DEFINE_RE = re.compile(r"^-D(\S+)$")

# 5. -CDEFINE+FOO  →  +define+FOO  (FuseSoC sometimes emits this)
CDEFINE_RE = re.compile(r"^-CDEFINE\+(.+)$")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def resolve(path_str: str, anchor: Path | None) -> str:
    """Optionally resolve a relative path against anchor."""
    if anchor is None:
        return path_str
    p = Path(path_str)
    if not p.is_absolute():
        p = (anchor / p).resolve()
    return str(p)


def transform_line(raw: str, anchor: Path | None, seen: set) -> str | None:
    """
    Return the transformed line string, or None to drop the line entirely.
    Trailing newline is preserved when present.
    """
    line = raw.rstrip("\n")
    stripped = line.strip()

    # ── blank lines and comments ──────────────────────────────────────────
    if not stripped or stripped.startswith("//") or stripped.startswith("#"):
        return raw

    # ── Verilator .vlt waiver files ───────────────────────────────────────
    if stripped.endswith(VLT_EXTENSION):
        return None

    # ── DROP by prefix ────────────────────────────────────────────────────
    for prefix in DROP_PREFIXES:
        if stripped.startswith(prefix):
            return None

    # ── +incdir+  (pass-through, but resolve path and dedup) ─────────────
    if stripped.startswith("+incdir+"):
        path_part = stripped[len("+incdir+"):]
        path_part = resolve(path_part, anchor)
        token = f"+incdir+{path_part}"
        if token in seen:
            return None
        seen.add(token)
        return token + "\n"

    # ── +define+  (pass-through, dedup) ──────────────────────────────────
    if stripped.startswith("+define+"):
        if stripped in seen:
            return None
        seen.add(stripped)
        return stripped + "\n"

    # ── -D<DEFINE>[=VALUE]  →  +define+<DEFINE>[=VALUE] ──────────────────
    m = DEFINE_RE.match(stripped)
    if m:
        token = f"+define+{m.group(1)}"
        if token in seen:
            return None
        seen.add(token)
        return token + "\n"

    # ── -CDEFINE+FOO  →  +define+FOO ─────────────────────────────────────
    m = CDEFINE_RE.match(stripped)
    if m:
        token = f"+define+{m.group(1)}"
        if token in seen:
            return None
        seen.add(token)
        return token + "\n"

    # ── -G<PARAM>=<VALUE>  →  -g<PARAM>=<VALUE>  (generic override) ──────
    m = GENERIC_RE.match(stripped)
    if m:
        token = f"-g{m.group(1)}={m.group(2)}"
        if token in seen:
            return None
        seen.add(token)
        return token + "\n"

    # ── -f <subfile>  (pass-through) ──────────────────────────────────────
    if stripped.startswith("-f ") or stripped == "-f":
        return raw

    # ── RTL source files (.sv / .v / .vhd / .vhdl) ───────────────────────
    lower = stripped.lower()
    if any(lower.endswith(ext) for ext in (".sv", ".v", ".vhd", ".vhdl")):
        resolved = resolve(stripped, anchor)
        if resolved in seen:
            return None
        seen.add(resolved)
        return resolved + "\n"

    # ── anything else: warn and drop ─────────────────────────────────────
    print(f"WARNING: unrecognised / dropped line: {stripped!r}", file=sys.stderr)
    return None


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Convert a Verilator flist to a QuestaSim-compatible flist."
    )
    parser.add_argument("input",  help="Input Verilator flist")
    parser.add_argument("output", help="Output QuestaSim flist")
    parser.add_argument(
        "--anchor", metavar="DIR", default=None,
        help="Directory used to resolve relative paths (default: leave as-is)"
    )
    args = parser.parse_args()

    anchor = Path(args.anchor).resolve() if args.anchor else None

    seen: set = set()
    dropped = 0
    kept = 0

    with open(args.input) as fin, open(args.output, "w") as fout:
        fout.write("// QuestaSim flist – generated by flist2questa.py\n")
        fout.write(f"// Source: {args.input}\n\n")
        for lineno, raw in enumerate(fin, 1):
            result = transform_line(raw, anchor, seen)
            if result is None:
                dropped += 1
            else:
                fout.write(result)
                kept += 1

    print(f"INFO: flist2questa.py complete")
    print(f"INFO:   input  : {args.input}")
    print(f"INFO:   output : {args.output}")
    print(f"INFO:   kept   : {kept} lines")
    print(f"INFO:   dropped: {dropped} lines")


if __name__ == "__main__":
    main()
