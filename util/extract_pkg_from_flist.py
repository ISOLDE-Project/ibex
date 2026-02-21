#!/usr/bin/env python3

import argparse
from pathlib import Path


def parse_args():
    parser = argparse.ArgumentParser(
        description="Extract *pkg.sv entries from a flist."
    )
    parser.add_argument("flist", type=Path, help="Input flist file")
    parser.add_argument("-o", "--output", type=Path, required=True,
                        help="Output file")
    return parser.parse_args()


def is_pkg_sv(line: str) -> bool:
    """Return True if the line is a SystemVerilog package file."""
    line = line.strip()

    if not line:
        return False

    # Skip tool directives
    if line.startswith("+incdir+"):
        return False
    if line.startswith("-"):
        return False

    # Match *_pkg.sv or *pkg.sv
    return line.endswith("pkg.sv")


def main():
    args = parse_args()

    flist = args.flist.resolve()
    output = args.output.resolve()

    matches = []

    with open(flist, "r") as f:
        for raw in f:
            line = raw.strip()

            if is_pkg_sv(line):
                matches.append(line)

    # Remove duplicates while preserving order
    matches = list(dict.fromkeys(matches))

    with open(output, "w") as f:
        for m in matches:
            f.write(m + "\n")

    print(f"Found {len(matches)} package files.")


if __name__ == "__main__":
    main()
