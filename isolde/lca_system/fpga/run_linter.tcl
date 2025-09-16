################################################################
# configure board
source ./board/xilinx.cfg
################################################################

set top_name [get_property top [current_fileset]]
puts "Current top module is: $top_name"

set_msg_config -severity {INFO} -suppress  ;# suppress all info messages
set_msg_config -severity {WARNING} -suppress ;# suppress all warnings

synth_design -top $top_name -part $part -lint 

#reset_msg_config -all