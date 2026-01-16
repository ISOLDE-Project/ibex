#!/usr/bin/env tclsh

# ---------------------------------------------------------
# Vivado Tcl → Yosys filelist converter
# ---------------------------------------------------------

# Storage
set ::yosys_files {}
set ::yosys_defines {}
set ::yosys_params {}
set ::yosys_incdirs {}
set ::blacklist {prim_generic_clock_gating.sv ibex_top_tracing.sv ibex_tracer_pkg.sv ibex_tracer.sv}

# ---------------------------------------------------------
# Vivado command stubs (we intercept instead of executing)
# ---------------------------------------------------------

proc set_property {prop value args} {
    switch -- $prop {
        verilog_define {
            foreach d $value {
                lappend ::yosys_defines $d
            }
        }
        generic {
            foreach {k v} $value {
                lappend ::yosys_params "$k=$v"
            }
        }
        default {
            # ignore
        }
    }
}

proc add_files {args} {
    # Look for a list argument
    foreach a $args {
        if {[llength $a] > 1} {
            foreach f $a {
                lappend ::yosys_files [file normalize $f]
            }
        }
    }
}

# Vivado helpers we don't care about
proc get_filesets {args} { return }
proc current_fileset {} { return }

# ---------------------------------------------------------
# Source the Vivado Tcl file
# ---------------------------------------------------------

if {$argc != 1} {
    puts stderr "Usage: tclsh vivado_tcl_to_yosys_f.tcl <vivado_file.tcl>"
    exit 1
}

source [lindex $argv 0]

# Capture include dirs if defined
if {[info exists ibex_include_dirs]} {
    foreach d $ibex_include_dirs {
        lappend ::yosys_incdirs [file normalize $d]
    }
}

# ---------------------------------------------------------
# Emit Yosys filelist
# ---------------------------------------------------------

set out "ibex-yosys.flist"
set f [open $out w]

puts $f "# Auto-generated from Vivado Tcl"




foreach d $::yosys_incdirs {
    puts $f "+incdir+$d"
}

# Slang/Yosys does NOT support parameter
foreach p $::yosys_params {
    puts $f "+define+$p"  
}

foreach d $::yosys_defines {
    if {[string match "RVFI*" $d]} {
        continue
    }
    if {[string match "FPGA_*" $d]} {
        continue
    }
    puts $f "+define+$d"
}

foreach fsrc $::yosys_files {
    # Extract filename from full path
    set fname [file tail $fsrc]

    # If filename is in blacklist, skip it
    if {[lsearch -exact $::blacklist $fname] != -1} {
        continue
    }

    puts $f $fsrc
}

close $f

puts "Generated $out"
