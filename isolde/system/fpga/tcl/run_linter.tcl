################################################################
# configure board
source $::env(FPGA_DIR)/board/xilinx.cfg
################################################################

open_project $::env(FPGA_DIR)/vivado/$project/$project.xpr
set top_name [get_property top [current_fileset]]
puts "Current top module is: $top_name"

set_msg_config -severity {INFO} -suppress  ;# suppress all info messages
set_msg_config -severity {WARNING} -suppress ;# suppress all warnings

synth_design -top $top_name -part $part -lint 

close_project