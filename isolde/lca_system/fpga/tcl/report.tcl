################################################################
# configure board
source $::env(FPGA_DIR)/board/xilinx.cfg
################################################################

open_project $::env(FPGA_DIR)/vivado/$project/$project.xpr

# Open the implemented design
open_run impl_1

# Generate a brief timing summary and save to file
report_timing_summary -delay_type max -max_paths 1 -file $::env(FPGA_DIR)/timing_summary.rpt

set timing_summary [report_timing_summary -return_timing_objects]
puts "WNS: [get_property STATS.WNS $timing_summary]"
puts "TNS: [get_property STATS.TNS $timing_summary]"
puts "WHS: [get_property STATS.WHS $timing_summary]"
puts "THS: [get_property STATS.THS $timing_summary]"
close_project