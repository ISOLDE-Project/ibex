################################################################
# configure board
source $::env(FPGA_DIR)/board/xilinx.cfg
################################################################

open_project $::env(FPGA_DIR)/vivado/$project/$project.xpr

# Open the implemented design
open_run impl_1

# Generate a brief timing summary and save to file
report_timing_summary -delay_type max -max_paths 1 -file $::env(FPGA_DIR)/timing_summary.rpt

proc report_brief_timing { {run_name "impl_1"} } {
    if {[llength [get_runs $run_name]] == 0} {
        puts "ERROR: run '$run_name' not found. Available runs: [get_runs]"
        return
    }
    open_run $run_name

    # Get setup/hold summaries
    set setup_str [report_timing_summary -delay_type max -return_string]
    set hold_str  [report_timing_summary -delay_type min -return_string]

    # Helper to extract column by header
    proc get_column_value {report_str column_name} {
        set lines [split $report_str "\n"]
        set header_line ""
        set data_line ""
        set found_header 0

        foreach line $lines {
            if {[string match "*$column_name*" $line]} {
                set header_line $line
                set found_header 1
            } elseif {$found_header} {
                # Skip dashed line
                if {[string match "-*" [string trim $line]]} {
                    continue
                }
                # Take first numeric line after header
                if {[regexp {[-+]?[0-9]*\.?[0-9]+} $line]} {
                    set data_line $line
                    break
                }
            }
        }

        if {$header_line eq "" || $data_line eq ""} { return "N/A" }

        # Split header & data into lists
        set headers [regexp -all -inline {\S+} $header_line]
        set values  [regexp -all -inline {\S+} $data_line]

        # Find index of column
        set idx [lsearch -exact $headers $column_name]
        if {$idx == -1 || $idx >= [llength $values]} { return "N/A" }
        return [lindex $values $idx]
    }

    set wns [get_column_value $setup_str "WNS(ns)"]
    set tns [get_column_value $setup_str "TNS(ns)"]
    set whs [get_column_value $hold_str  "WHS(ns)"]
    set ths [get_column_value $hold_str  "THS(ns)"]

    puts "=== BRIEF TIMING SUMMARY ($run_name) ==="
    puts "WNS = $wns ns"
    puts "TNS = $tns ns"
    puts "WHS = $whs ns"
    puts "THS = $ths ns"
}



report_brief_timing

close_project