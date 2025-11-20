import argparse
from intelhex import IntelHex


def load_original_hex(filename):
    """
    Load your custom @ADDRESS hex-dump format into a dictionary.
    """
    memory = {}
    current_addr = None

    with open(filename, "r") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue

            if line.startswith("@"):
                current_addr = int(line[1:], 16)
                continue

            for byte in line.split():
                memory[current_addr] = int(byte, 16)
                current_addr += 1

    return memory

def compute_trimmed_end(memory, start_addr, user_end_addr, align=16):
    """
    Find the last non-zero byte within the requested range and align
    the resulting end address upward to the given alignment.

    If the whole range is zero, return start_addr aligned upward.
    """
    last_nonzero = None

    # search backwards for last non-zero location
    for addr in range(user_end_addr, start_addr - 1, -1):
        if memory.get(addr, 0) != 0:
            last_nonzero = addr
            break

    if last_nonzero is None:
        # everything is zero → minimal aligned region
        return (start_addr + (align - 1)) & ~(align - 1)

    # align upward
    last_address = (last_nonzero + (align - 1)) & ~(align - 1)
    # print(f"@{last_address:08X}\n")
    return last_address


def save_original_format(filename, memory, start, end):
    """
    Save output in your original @ADDRESS dump format.
    """
    with open(filename, "w") as f:
        f.write(f"@{start-start:08X}\n")
        line = []

        for addr in range(start, end + 1):
            val = memory.get(addr, 0)
            line.append(f"{val:02X}")

            if len(line) == 16:
                f.write(" ".join(line) + "\n")
                line = []

        if line:
            f.write(" ".join(line) + "\n")


def save_intel_hex(filename, memory, start, end):
    """
    Save selected memory range as Intel HEX using the IntelHex package.
    """
    ih = IntelHex()

    for addr in range(start, end + 1):
        ih[addr] = memory.get(addr, 0)

    ih.write_hex_file(filename)


def parse_args():
    parser = argparse.ArgumentParser(
        description="Extract an address range from a custom hex file and output in two formats."
    )

    parser.add_argument("input", help="Input hex file in @ADDRESS format")
    parser.add_argument("start", help="Start address (hex), e.g. 0x00000000")
    parser.add_argument("end", help="End address (hex), e.g. 0x000000FF")
    parser.add_argument("output_base", help="Base name for output files (without extension)")

    return parser.parse_args()


def main():
    args = parse_args()

    start_addr = int(args.start, 16)
    end_addr  = int(args.end, 16)

    memory = load_original_hex(args.input)
    end_addr=compute_trimmed_end(memory=memory, start_addr=start_addr, user_end_addr=end_addr)
    byte_count = end_addr-start_addr
    # Output: original format
    out_original = args.output_base + ".hex"
    save_original_format(out_original, memory, start_addr, end_addr)

    # Output: Intel HEX
    out_ihex = args.output_base + ".ihex"
    save_intel_hex(out_ihex, memory, start_addr, end_addr)

    print("Generated files:")
    print(f"⚠️  {byte_count//4} words ({byte_count} bytes) → 0x{start_addr:08X} - 0x{end_addr - 1:08X}")
    print(f"📦  {out_original}")
    print(f"📦  {out_ihex}")
    print(f"✅ \n")


if __name__ == "__main__":
    main()
