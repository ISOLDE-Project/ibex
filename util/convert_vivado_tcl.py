import argparse

def main():
    parser = argparse.ArgumentParser(description="Convert read_verilog commands to add_files TCL format.")
    parser.add_argument("input_file", help="Path to input file containing read_verilog commands.")
    parser.add_argument("output_file", help="Path to output TCL file.")
    parser.add_argument("root", help="Root directory to set as ROOT_IBEX in the output.")
    args = parser.parse_args()

    file_paths = []
    include_dirs_line = None
    property_generic =""
    
    # Read input file
    with open(args.input_file, "r") as f:
        for line in f:
            line = line.strip()
            if line.startswith("read_verilog"):
                start = line.find("{") + 1
                end = line.find("}")
                if start > 0 and end > start:
                    file_paths.append(line[start:end])
                        # Capture include_dirs line
            elif line.startswith("set_property include_dirs"):
                include_dirs_line = line
            elif line.startswith(("set_property generic", "set_property verilog_define")):
                property_generic = f'{property_generic}\n{line}\n'
            


    # Write output file
    with open(args.output_file, "w") as f:
        f.write(f'set_property source_mgmt_mode None [current_project]\n')
        f.write(f'{property_generic}\n')
        f.write(f'set ROOT_IBEX "{args.root}"\n')
        f.write("add_files -norecurse -fileset [current_fileset] [list \\\n")
        for path in file_paths:
            f.write(f"    $ROOT_IBEX/{path} \\\n")
        f.write("]\n")
    
           # Rewrite include_dirs line
        if include_dirs_line:
            # Extract paths between "list" and "]"
            start = include_dirs_line.find("list") + len("list")
            end = include_dirs_line.find("]", start)
            raw_paths = include_dirs_line[start:end].split()

            converted_paths = []
            for p in raw_paths:
                    converted_paths.append(f"$ROOT_IBEX/{p}")

            new_include_line = (
                f"set_property include_dirs [list {' '.join(converted_paths)}] [get_filesets sources_1]"
            )
            f.write(new_include_line + "\n")

    print(f"✅ Output written to {args.output_file}")

if __name__ == "__main__":
    main()
