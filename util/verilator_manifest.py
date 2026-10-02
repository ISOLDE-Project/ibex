#!/usr/bin/env python3

import argparse
from pathlib import Path

import yaml


def parse_args():
    parser = argparse.ArgumentParser(
        description="Append target-specific sources from Verilator.yml to a file list."
    )
    parser.add_argument("manifest_file", type=Path, help="Path to Verilator.yml")
    parser.add_argument(
        "-t",
        "--target",
        action="append",
        required=True,
        help="Target to append; may be specified more than once",
    )
    parser.add_argument(
        "-o", "--output", type=Path, required=True, help="File to append output to"
    )
    return parser.parse_args()


def string_list(value, field, target):
    if value is None:
        return []
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise ValueError(f"sources.{target}.{field} must be a list of paths")
    return value


def target_config(sources, target):
    if target not in sources:
        available = ", ".join(sorted(sources)) or "<none>"
        raise ValueError(f"unknown target '{target}'; available targets: {available}")

    config = sources[target]

    # Backward compatibility with the original format:
    # sources:
    #   vanilla:
    #     - sim/core/tb_top_verilator.cpp
    if isinstance(config, list):
        return string_list(config, "files", target), []

    if not isinstance(config, dict):
        raise ValueError(f"sources.{target} must be a list or mapping")

    unknown_fields = set(config) - {"files", "include_dirs"}
    if unknown_fields:
        fields = ", ".join(sorted(unknown_fields))
        raise ValueError(f"sources.{target} has unknown field(s): {fields}")

    files = string_list(config.get("files"), "files", target)
    include_dirs = string_list(config.get("include_dirs"), "include_dirs", target)
    return files, include_dirs


def resolve_path(base_dir, path, kind):
    resolved = (base_dir / path).resolve()
    exists = resolved.is_dir() if kind == "directory" else resolved.is_file()
    if not exists:
        raise ValueError(f"{kind} does not exist: {resolved}")
    return resolved


def append_unique(items, output, seen):
    for item in items:
        if item not in seen:
            seen.add(item)
            output.append(item)


def main():
    args = parse_args()
    manifest_file = args.manifest_file.resolve()
    output_file = args.output.resolve()
    manifest_dir = manifest_file.parent

    try:
        with manifest_file.open("r", encoding="utf-8") as manifest:
            data = yaml.safe_load(manifest)

        if not isinstance(data, dict):
            raise ValueError("manifest root must be a mapping")

        sources = data.get("sources")
        if not isinstance(sources, dict):
            raise ValueError("'sources' must be a mapping of target names")

        files = []
        include_dirs = []
        seen_files = set()
        seen_include_dirs = set()

        for target in args.target:
            target_files, target_include_dirs = target_config(sources, target)
            append_unique(
                (resolve_path(manifest_dir, path, "file") for path in target_files),
                files,
                seen_files,
            )
            append_unique(
                (
                    resolve_path(manifest_dir, path, "directory")
                    for path in target_include_dirs
                ),
                include_dirs,
                seen_include_dirs,
            )
    except (OSError, ValueError, yaml.YAMLError) as error:
        raise SystemExit(f"{manifest_file}: {error}") from error

    with output_file.open("a", encoding="utf-8") as output:
        for include_dir in include_dirs:
            output.write(f"+incdir+{include_dir}\n")
            output.write(f'-CFLAGS "-I{include_dir}"\n')

        for source in files:
            output.write(f"{source}\n")


if __name__ == "__main__":
    main()
