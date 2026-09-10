#!/usr/bin/env python3
"""
Render ISOLDE RTL packages, the XIF relay and the BSP linker script from one
YAML platform description.

    ./gen_isolde_rtl.py --batch jobs.yml
    ./gen_isolde_rtl.py --platform fpga_large --template link.ld.j2 -o /tmp/link.ld
    ./gen_isolde_rtl.py --platform sim --check          # CI: regen and diff

Every output is a committed file; --check re-renders into memory and diffs
against what is on disk, so "edited platform.yml, forgot to regenerate" fails
at review time instead of at synthesis time.
"""
import argparse
import difflib
import sys
from pathlib import Path

import yaml
from jinja2 import Environment, FileSystemLoader, StrictUndefined

REQUIRED_REGIONS = ("instrram", "dataram", "stack")


# --------------------------------------------------------------------------
# SystemVerilog literal filters
# --------------------------------------------------------------------------

def sv32(value: int) -> str:
    """0x100000 -> 32'h0010_0000  (matches the existing hand-written style)."""
    h = f"{int(value):08x}".upper()
    return f"32'h{h[:4]}_{h[4:]}"


def sv32short(value: int) -> str:
    """0x200 -> 32'h200 (unpadded form used for SMEM_SIZE_I32)."""
    return f"32'h{int(value):x}".upper().replace("32'H", "32'h")


# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------

def _as_int(v) -> int:
    return v if isinstance(v, int) else int(str(v), 0)


def load_platforms(path: Path) -> dict:
    if not path.is_file():
        raise SystemExit(f"platform config not found: {path}")
    data = yaml.safe_load(path.read_text()) or {}
    platforms = data.get("platforms")
    if not platforms:
        raise SystemExit(f"no 'platforms:' section in {path}")
    return platforms


def build_context(platforms: dict, platform: str, n_tiles: int = None) -> dict:
    if platform not in platforms:
        raise SystemExit(
            f"unknown platform {platform!r}; available: {', '.join(sorted(platforms))}"
        )
    entry = platforms[platform]
    ctx = {"platform": platform}

    ctx["n_tiles"] = int(n_tiles if n_tiles is not None else entry["n_tiles"])
    if ctx["n_tiles"] < 1:
        raise SystemExit(f"n_tiles must be >= 1 (got {ctx['n_tiles']})")

    mem_in = entry.get("memory", {})
    missing = [r for r in REQUIRED_REGIONS if r not in mem_in]
    if missing:
        raise SystemExit(
            f"platform {platform!r}: missing memory region(s): {', '.join(missing)}"
        )

    # Preserve declaration order for link.ld; require the three known regions.
    memory = {}
    for region, cfg in mem_in.items():
        origin = _as_int(cfg["origin"])
        length = _as_int(cfg["length"])
        if length % 4:
            raise SystemExit(
                f"platform {platform!r}: region {region!r} length 0x{length:x} "
                "is not a multiple of 4; aida_pkg.sv sizes SRAM in 32-bit words"
            )
        if length == 0:
            raise SystemExit(f"platform {platform!r}: region {region!r} has zero length")
        memory[region] = {
            "origin": origin,
            "length": length,
            "length_i32": length // 4,
            "end": origin + length,
        }
    ctx["memory"] = memory

    # Overlap check across the declared regions.
    ordered = sorted(memory.items(), key=lambda kv: kv[1]["origin"])
    for (an, a), (bn, b) in zip(ordered, ordered[1:]):
        if a["end"] > b["origin"]:
            raise SystemExit(
                f"platform {platform!r}: {an} [0x{a['origin']:08x},0x{a['end']:08x}) "
                f"overlaps {bn} [0x{b['origin']:08x},0x{b['end']:08x})"
            )

    boot_off = _as_int(entry.get("boot_offset", 0x80))
    if boot_off >= memory["instrram"]["length"]:
        raise SystemExit(
            f"platform {platform!r}: boot_offset 0x{boot_off:x} lies outside instrram"
        )
    ctx["boot_offset"] = memory["instrram"]["origin"] + boot_off

    spm = entry.get("spm", {})
    base = _as_int(spm.get("narrow_addr_base", 0x80001000))
    size = _as_int(spm.get("narrow_size", 0x8000))
    ctx["spm"] = {"narrow_addr_base": base, "narrow_size": size}

    # The aggregate SPM window must not collide with the core memory map.
    spm_end = base + ctx["n_tiles"] * size
    for name, r in memory.items():
        if base < r["end"] and r["origin"] < spm_end:
            raise SystemExit(
                f"platform {platform!r}: SPM window [0x{base:08x},0x{spm_end:08x}) "
                f"for {ctx['n_tiles']} tiles overlaps {name}"
            )
    return ctx


# --------------------------------------------------------------------------
# Rendering
# --------------------------------------------------------------------------

def make_env(template_dir: str) -> Environment:
    env = Environment(
        loader=FileSystemLoader(template_dir),
        trim_blocks=True,
        lstrip_blocks=True,
        keep_trailing_newline=True,
        undefined=StrictUndefined,
    )
    env.filters["sv32"] = sv32
    env.filters["sv32short"] = sv32short
    return env


def render(env: Environment, template: str, ctx: dict) -> str:
    return env.get_template(template).render(**ctx)


def emit(text: str, output: Path, check: bool) -> bool:
    """Write, or in --check mode diff against what is committed. True == ok."""
    if not check:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(text)
        return True
    if not output.is_file():
        print(f"[STALE] {output}: does not exist", file=sys.stderr)
        return False
    current = output.read_text()
    if current == text:
        return True
    print(f"[STALE] {output}: committed file differs from platform.yml", file=sys.stderr)
    for line in list(difflib.unified_diff(
            current.splitlines(True), text.splitlines(True),
            fromfile=f"{output} (committed)", tofile=f"{output} (regenerated)"))[:40]:
        sys.stderr.write("    " + line)
    return False


def main() -> int:
    ap = argparse.ArgumentParser()
    here = Path(__file__).parent
    ap.add_argument("--config", default=str(here / "platform.yml"))
    ap.add_argument("--template-dir", default=str(here / "templates"))
    ap.add_argument("--batch", help="jobs YAML")
    ap.add_argument("--platform")
    ap.add_argument("--n-tiles", type=int)
    ap.add_argument("--template")
    ap.add_argument("-o", "--output")
    ap.add_argument("--root", default=".", help="repo root for relative job outputs")
    ap.add_argument("--check", action="store_true",
                    help="do not write; fail if committed files are stale")
    args = ap.parse_args()

    platforms = load_platforms(Path(args.config))
    env = make_env(args.template_dir)
    root = Path(args.root)

    if args.batch:
        jobs = (yaml.safe_load(Path(args.batch).read_text()) or {}).get("jobs", [])
        if not jobs:
            raise SystemExit(f"no 'jobs:' in {args.batch}")
        ok = True
        for i, job in enumerate(jobs):
            plat = job.get("platform", args.platform)
            if plat is None:
                raise SystemExit(f"job #{i}: no platform and no --platform given")
            ctx = build_context(platforms, plat, job.get("n_tiles"))
            out = root / job["output"]
            good = emit(render(env, job["template"], ctx), out, args.check)
            ok &= good
            if good and not args.check:
                print(f"[ok] {out}  (platform={plat}, N_TILES={ctx['n_tiles']})",
                      file=sys.stderr)
        if not ok:
            print("\nRun `make generate` and commit the result.", file=sys.stderr)
            return 1
        print("\nall generated files are up to date" if args.check
              else f"\n{len(jobs)} file(s) generated", file=sys.stderr)
        return 0

    if not args.platform or not args.template:
        raise SystemExit("need --batch, or --platform with --template")
    ctx = build_context(platforms, args.platform, args.n_tiles)
    text = render(env, args.template, ctx)
    if args.output:
        return 0 if emit(text, Path(args.output), args.check) else 1
    sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
