import argparse

def main():
    parser = argparse.ArgumentParser(description="Convert read_verilog commands to add_files TCL format.")
    parser.add_argument("input_file", help="Path to input file containing read_verilog commands.")
    parser.add_argument("output_file", help="Path to output TCL file.")
    parser.add_argument("root", help="Root directory to set as ROOT in the output.")
    args = parser.parse_args()

    file_paths = []
    
    # Read input file
    with open(args.input_file, "r") as f:
        for line in f:
            line = line.strip()
            if line.startswith("read_verilog"):
                start = line.find("{") + 1
                end = line.find("}")
                if start > 0 and end > start:
                    file_paths.append(line[start:end])

    # Write output file
    with open(args.output_file, "w") as f:
        f.write(f'set ROOT "{args.root}"\n')
        f.write("add_files -norecurse -fileset [current_fileset] [list \\\n")
        for path in file_paths:
            f.write(f"    $ROOT/{path} \\\n")
        f.write("]\n")

    print(f"✅ Output written to {args.output_file}")

if __name__ == "__main__":
    main()
