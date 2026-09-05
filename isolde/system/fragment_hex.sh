#!/usr/bin/env bash
#set -euo pipefail

# Usage:
#   SCRIPTS_DIR=/path/to/scripts ./fragment_hex.sh [root_dir]
#
# Example:
#   SCRIPTS_DIR=./scripts ./fragment_hex.sh isolde/system/nxp-ro
#
# If root_dir is omitted, the folder structure from the project is used.

SCRIPTS_DIR=$ROOT_DIR/isolde/scripts
TESTS_DIR=$ROOT_DIR/isolde/system/nxp-ro

if [[ -z "${SCRIPTS_DIR:-}" ]]; then
    echo "ERROR: SCRIPTS_DIR is not set." >&2
    echo "make sure you executed . ./eth.sh before running this script" >&2
    exit 1
fi

HEX_FRAGMENT="${SCRIPTS_DIR}/hex_fragment.py"

if [[ ! -f "$HEX_FRAGMENT" ]]; then
    echo "ERROR: Cannot find: $HEX_FRAGMENT" >&2
    exit 1
fi

if [[ ! -d "$TESTS_DIR" ]]; then
    echo "ERROR: Cannot find root directory: $TESTS_DIR" >&2
    exit 1
fi

count=0

while IFS= read -r -d '' elf_file; do
    # omp_test.hex -> omp_test
    stem="${elf_file%.elf}"

    hex_file="${stem}.hex"
    m_file="${stem}-m"
    d_file="${stem}-d"


    echo "Processing: $elf_file"
    echo "  -> $m_file"
    $ROOT_DIR/install/riscv-llvm/bin/riscv32-unknown-elf-objcopy -O verilog "$elf_file" "$hex_file"
    python "$HEX_FRAGMENT" \
        "$hex_file" \
        0x00100000 \
        0x0010FFFF \
        "$m_file"

    echo "  -> $d_file"
    python "$HEX_FRAGMENT" \
        "$hex_file" \
        0x00110000 \
        0x00140000 \
        "$d_file"

    count=$((count + 1))
done < <(
    find "$TESTS_DIR" \
        -mindepth 2 \
        -maxdepth 2 \
        -type f \
        -name 'omp_test.elf' \
        -print0
)

echo
echo "Done. Processed $count omp_test.elf file(s)."
