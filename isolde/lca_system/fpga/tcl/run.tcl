################################################################
# configure board
source $::env(FPGA_DIR)/board/xilinx.cfg
################################################################

open_project $::env(FPGA_DIR)/vivado/$project/$project.xpr
set_msg_config -severity {INFO} -suppress  ;# suppress all info messages
#set_msg_config -severity {WARNING} -suppress ;# suppress all warnings

launch_runs synth_1  -jobs 12
wait_on_runs synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 12
wait_on_runs impl_1
close_project
