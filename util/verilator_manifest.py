#!/usr/bin/env python3

import sys
import yaml
import argparse
from pathlib import Path


def parse_args():
    parser = argparse.ArgumentParser(
        description="Extract Verilator C++ sources from Manifest.yml."
    )
    parser.add_argument("yaml_file", type=Path, help="Path to Manifest.yml")
    parser.add_argument("-t", "--target", required=True,
                        help="Target name in sources")
    parser.add_argument("-o", "--output", type=Path, required=True,
                        help="File to append output to")
    return parser.parse_args()


def get_cpp_sources(manifest_yaml_path, target):
    with open(manifest_yaml_path, "r") as f:
        data = yaml.safe_load(f) or {}

    sources = data.get("sources", {})
    result = []

    # ------------------------------
    # Case 1: dict-style sources
    #
    # sources:
    #   default:
    #     - a.cpp
    #   vanilla:
    #     - b.cpp
    # ------------------------------
    if isinstance(sources, dict):
        # Always include default if present
        result.extend(sources.get("default", []))

        # Include target-specific
        result.extend(sources.get(target, []))

    # ------------------------------
    # Case 2: list-style sources
    #
    # sources:
    #   - files: [...]
    #     target: vanilla
    # ------------------------------
    elif isinstance(sources, list):
        for entry in sources:
            if isinstance(entry, dict):
                files = entry.get("files", [])
                entry_target = entry.get("target")

                # Include if:
                #  - no target specified (global)
                #  - target matches
                if entry_target is None or entry_target == target:
                    result.extend(files)

            elif isinstance(entry, str):
                # plain file entry
                result.append(entry)

    return result

def get_defines(yaml_path: Path, target: str):
    with open(yaml_path, "r") as f:
        data = yaml.safe_load(f) or {}

    defines_section = data.get("defines", {})

    if target not in defines_section:
        return []

    target_defines = defines_section[target]

    if not isinstance(target_defines, dict):
        raise RuntimeError(f"'defines:{target}' must be a mapping")

    result = []
    for key, value in target_defines.items():
        if value is None:
            result.append(f"-D{key}")
        else:
            result.append(f"-D{key}={value}")

    return result

def main():
    args = parse_args()

    yaml_file = args.yaml_file.resolve()
    target = args.target
    output_file = args.output.resolve()
    bender_dir = yaml_file.parent

    cpp_files = get_cpp_sources(yaml_file, target)

    if not cpp_files:
        print(f"[WARNING] No sources found for target '{target}'", file=sys.stderr)


    defines = get_defines(yaml_file, target)

    if not defines:
        print(f"[WARNING] No defines found for target '{target}'", file=sys.stderr)

    with open(output_file, "a") as f:
        for rel_path in cpp_files:
            abs_path = (bender_dir / rel_path).resolve()
            f.write(f"{abs_path}\n")
        for d in defines:
            f.write(d + "\n")


if __name__ == "__main__":
    main()
