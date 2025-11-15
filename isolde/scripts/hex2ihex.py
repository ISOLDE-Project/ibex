import argparse
from intelhex import IntelHex

def main():
    parser = argparse.ArgumentParser(description="Convert raw HEX file to Intel HEX format")
    parser.add_argument("--input", required=True, help="Input HEX file")
    parser.add_argument("--base", required=True, help="Base address (e.g., 0x00100000)")
    parser.add_argument("--output", default="instr.hex", help="Output file")
    args = parser.parse_args()

    base_address = int(args.base, 16)  # Convert base address from hex string to int

    ih = IntelHex()
    current_address = None

    with open(args.input, "r") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            if line.startswith('@'):
                # Update current address
                current_address = base_address + int(line[1:], 16)
            else:
                # Split line into bytes and store in IntelHex
                byte_strs = line.split()
                for b in byte_strs:
                    ih[current_address] = int(b, 16)
                    current_address += 1

    ih.write_hex_file(args.output)
    print(f"Intel HEX file written to {args.output}")

if __name__ == "__main__":
    main()
