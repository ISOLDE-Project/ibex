import argparse
from intelhex import IntelHex

def main():
    parser = argparse.ArgumentParser(description="Convert raw HEX file to Intel HEX format")
    parser.add_argument("--input", required=True, help="Input HEX file")
    parser.add_argument("--base", required=True, help="Base address (e.g., 0x00100000)")
    parser.add_argument("--region_size", required=True, help="Maximum allowed region size (bytes)")
    parser.add_argument("--output", default="instr.hex", help="Output file")
    args = parser.parse_args()

    # numeric conversions
    base_address = int(args.base, 16)
    region_size = int(args.region_size, 0)   # supports hex like 0x4000 or decimal

    ih = IntelHex()
    current_address = None
    byte_count = 0
    limit_reached = False

    with open(args.input, "r") as f:
        for line_num, line in enumerate(f, 1):
            line = line.strip()

            if not line:
                continue

            # Handle @address directive
            if line.startswith('@'):
                try:
                    offset = int(line[1:], 16)
                except ValueError:
                    print(f"⚠️ Warning: Invalid address on line {line_num}: {line}")
                    continue

                current_address = base_address + offset
                continue

            # Data before first @address
            if current_address is None:
                print(f"⚠️ Warning: Data encountered before @address at line {line_num}. Skipped.")
                continue

            # Process byte list
            for b in line.split():
                if byte_count >= region_size:
                    limit_reached = True
                    break

                try:
                    value = int(b, 16)
                except ValueError:
                    print(f"⚠️ Warning: Invalid byte '{b}' on line {line_num}. Skipped.")
                    continue

                ih[current_address] = value
                current_address += 1
                byte_count += 1

            if limit_reached:
                break

    ih.write_hex_file(args.output)

    # Summary
    print(f"✅ {args.output}")
    if limit_reached:
        print(f"⚠️ Warning: region_size limit reached ({region_size} bytes). Extra data was ignored.")
    print(f"📦  {byte_count//4} words, 0x{base_address:08X} - 0x{current_address - 1:08X} → ")


if __name__ == "__main__":
    main()
