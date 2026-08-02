#!/usr/bin/env python3
"""
Render isolde_xif_relay.sv from isolde_xif_relay.sv.j2 for a given N_TILES.

Usage:
    python3 gen_isolde_xif_relay.py --n-tiles 4 -o isolde_xif_relay.sv
"""
import argparse
from pathlib import Path

from jinja2 import Environment, FileSystemLoader, StrictUndefined


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n-tiles", type=int, required=True,
                     help="Number of tiles (must be >= 1)")
    ap.add_argument("--template-dir", default=str(Path(__file__).parent))
    ap.add_argument("--template", default="isolde_xif_relay.sv.j2")
    ap.add_argument("-o", "--output", default=None,
                     help="Output .sv path (default: stdout)")
    args = ap.parse_args()

    if args.n_tiles < 1:
        raise SystemExit("N_TILES must be >= 1")

    env = Environment(
        loader=FileSystemLoader(args.template_dir),
        trim_blocks=True,
        lstrip_blocks=True,
        undefined=StrictUndefined,
    )
    template = env.get_template(args.template)
    rendered = template.render(n_tiles=args.n_tiles)

    if args.output:
        Path(args.output).write_text(rendered)
        print(f"Wrote {args.output} (N_TILES={args.n_tiles})")
    else:
        print(rendered)


if __name__ == "__main__":
    main()