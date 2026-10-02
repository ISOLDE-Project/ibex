import argparse
import re

def parse_verilog_define(line):
    """
    Extracts the content inside {} of a verilog_define line
    and returns a dict of key=value pairs, filtering out RVFI.
    """
    match = re.search(r'\{([^}]*)\}', line)
    if not match:
        return {}
    # Split into key=value pairs
    defines_dict = dict(d.split("=", 1) for d in match.group(1).split())
    # Remove RVFI if present
    defines_dict.pop("RVFI", None)
    return defines_dict
    

def main():
    parser = argparse.ArgumentParser(description="Convert read_verilog commands to add_files TCL format.")
    parser.add_argument("input_file", help="Path to input file containing read_verilog commands.")
    parser.add_argument("output_file", help="Path to output TCL file.")
    parser.add_argument("root", help="Root directory to set as ROOT_IBEX in the output.")
    args = parser.parse_args()

    file_paths = []
    include_dirs_line = None
    property_generic =""
    verilog_defines = {}

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
            elif line.startswith("set_property generic"):
                property_generic = f'{property_generic}\n{line}\n'
            elif line.startswith( "set_property verilog_define"):
                defines = parse_verilog_define(line)
                verilog_defines.update(defines)
            


    # Write output file
    with open(args.output_file, "w") as f:

        f.write(f'{property_generic}\n')

        if verilog_defines:
            defines_str = " ".join(f"{k}={v}" for k, v in verilog_defines.items())
            # Do NOT set the property here. `verilog_define` is a fileset
            # property, so `set_property` REPLACES it, and the bender-generated
            # part of vivado_synth.tcl (which is concatenated after this file)
            # would silently drop these defines. Export them instead and let
            # tcl/create_project.tcl merge them in, the same way it already
            # does for $ibex_include_dirs.
            f.write(f"set ibex_verilog_defines [list {defines_str}]\n\n")

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
                f"set ibex_include_dirs [list {' '.join(converted_paths)}] "
            )
            f.write(new_include_line + "\n")

    print(f"✅ Output written to {args.output_file}")

if __name__ == "__main__":
    main()
