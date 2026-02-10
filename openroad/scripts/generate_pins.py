#!/usr/bin/env python3
"""
generate_pins.py
Generate vanilla OpenROAD-compatible pin_placement.tcl from a Yosys netlist.
Each pin is defined with `set_io -pin` and given a manual X/Y location.
"""

import re
import argparse
from collections import defaultdict
from pathlib import Path

# ------------------------
# MODULE EXTRACTION
# ------------------------
def extract_module(verilog_text, module_name):
    """
    Extract the text of a specific Verilog module.
    """
    pattern = re.compile(
        rf'\bmodule\s+{re.escape(module_name)}\b.*?\bendmodule\b',
        re.DOTALL
    )

    match = pattern.search(verilog_text)
    if not match:
        raise ValueError(f"Module '{module_name}' not found in netlist")

    return match.group(0)


# ------------------------
# PORT PARSING
# ------------------------
def parse_ports(verilog_text):
    """
    Extract ports from Yosys-style netlist.
    Returns list of dicts: {name, dir, msb, lsb}
    """
    port_pattern = re.compile(
        r'\b(input|output|inout)\s+(?:wire|logic|reg)?\s*(\[[^]]+\])?\s*([a-zA-Z0-9_]+)',
        re.MULTILINE
    )

    ports = []
    for direction, width, name in port_pattern.findall(verilog_text):
        if width:
            nums = re.findall(r'\d+', width)
            msb = int(nums[0])
            lsb = int(nums[1])
        else:
            msb = 0
            lsb = 0

        ports.append({
            "name": name,
            "dir": direction,
            "msb": msb,
            "lsb": lsb
        })

    return ports


def bus_expand(name, msb, lsb):
    """
    Flatten bus names to _0_, _1_, ... style used in netlist.
    """
    if msb == lsb:
        return [name]

    step = 1 if msb <= lsb else -1
    return [f"{name}_{i}_" for i in range(msb, lsb + step, step)]


# ------------------------
# PORT CLASSIFICATION
# ------------------------
def classify_ports(ports):
    """
    Classify pins by side for manual placement.
    """
    groups = defaultdict(list)
    for p in ports:
        pins = bus_expand(p["name"], p["msb"], p["lsb"])
        name_lower = p["name"].lower()

        if "clk" in name_lower or "clock" in name_lower:
            groups["top"].extend(pins)
        elif "rst" in name_lower or "reset" in name_lower:
            groups["top"].extend(pins)
        elif p["dir"] == "input":
            groups["left"].extend(pins)
        elif p["dir"] == "output":
            groups["right"].extend(pins)
        else:
            groups["bottom"].extend(pins)

    return groups


# ------------------------
# TCL WRITER
# ------------------------
def write_tcl(groups, output_path, chip_width=800.0, chip_height=800.0):
    with open(output_path, "w") as f:
        f.write("############################################################\n")
        f.write("# AUTO-GENERATED VANILLA OPENROAD PIN PLACEMENT TCL\n")
        f.write("############################################################\n\n")

        f.write("set IO_LAYER {Metal3}\n\n")

        margin = 20.0

        for side in ["top", "left", "right", "bottom"]:
            pins = groups.get(side, [])
            if not pins:
                continue

            f.write(f"# ----------------\n# {side.upper()} PINS\n# ----------------\n")

            n = len(pins)
            for idx, pin in enumerate(pins):
                f.write(f"set_io -pin {pin}\n")

                if side == "top":
                    x = margin + (chip_width - 2*margin) * idx / max(n-1, 1)
                    y = chip_height
                elif side == "bottom":
                    x = margin + (chip_width - 2*margin) * idx / max(n-1, 1)
                    y = 0
                elif side == "left":
                    x = 0
                    y = margin + (chip_height - 2*margin) * idx / max(n-1, 1)
                else:  # right
                    x = chip_width
                    y = margin + (chip_height - 2*margin) * idx / max(n-1, 1)

                f.write(
                    f"place_pin -pin_name {pin} -layer $IO_LAYER "
                    f"-location {{{x:.2f} {y:.2f}}}\n"
                )


# ------------------------
# MAIN
# ------------------------
def main():
    parser = argparse.ArgumentParser(
        description="Generate vanilla OpenROAD pin_placement.tcl from Yosys netlist"
    )
    parser.add_argument("netlist", help="Input synthesized Verilog netlist")
    parser.add_argument("-m", "--module", required=True, help="Top module name to parse")
    parser.add_argument("-o", "--output", required=True, help="Output TCL pin placement file")
    parser.add_argument("-w", "--width", required=True, type=float, help="Chip width in microns")
    parser.add_argument("-H", "--height", required=True, type=float, help="Chip height in microns")
    args = parser.parse_args()

    netlist_path = Path(args.netlist)
    output_path = Path(args.output)

    if not netlist_path.exists():
        raise FileNotFoundError(f"Netlist not found: {netlist_path}")

    with open(netlist_path) as f:
        text = f.read()

    module_text = extract_module(text, args.module)
    ports = parse_ports(module_text)
    groups = classify_ports(ports)
    write_tcl(groups, output_path, chip_width=args.width, chip_height=args.height)

    total_pins = sum(len(pins) for pins in groups.values())
    print(f"🌟 Chip dimensions: {args.width} x {args.height} microns")
    print(f"✅ Module: {args.module}")
    print(f"✅ Generated {output_path}")
    print(f"✅ Parsed {len(ports)} ports → {total_pins} IO pins placed")
     


if __name__ == "__main__":
    main()

