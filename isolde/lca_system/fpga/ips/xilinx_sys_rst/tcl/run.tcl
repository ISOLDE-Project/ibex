source $::env(FPGA_DIR)/tcl/common.tcl


set xilinx_ip "${ipName}_ip" 
##################################################################
# CREATE IP 
##################################################################

set $xilinx_ip [create_ip -name proc_sys_reset -vendor xilinx.com -library ip -module_name $ipName]

set_property CONFIG.RESET_BOARD_INTERFACE {reset} [get_ips $ipName]

##################################################################
# Run synthesis
##################################################################
create_ip_run [get_ips $ipName]
launch_run -jobs 8 ${ipName}_synth_1
wait_on_run ${ipName}_synth_1
