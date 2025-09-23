################################################################
# configure board
source ../board/xilinx.cfg
################################################################

set top_name [get_property top [current_fileset]]
puts "Current top module is: $top_name"

set_msg_config -severity {INFO} -suppress  ;# suppress all info messages
#set_msg_config -severity {WARNING} -suppress ;# suppress all warnings

launch_runs synth_1  -jobs 12
wait_on_runs synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 12
wait_on_runs impl_1
close_project
