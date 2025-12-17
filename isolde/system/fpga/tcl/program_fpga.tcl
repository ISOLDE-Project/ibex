open_hw_manager
connect_hw_server -url localhost:3121 -allow_non_jtag
current_hw_target [get_hw_targets */xilinx_tcf/Xilinx/29390A]
set_property PARAM.FREQUENCY 15000000 [get_hw_targets */xilinx_tcf/Xilinx/29390A]
open_hw_target
set_property PROGRAM.FILE {/home/dan/ibex/isolde/lca_system/fpga/vivado/aida-zcu104/aida-zcu104.runs/impl_1/xilinx_aida.bit} [get_hw_devices xczu7_0]
current_hw_device [get_hw_devices xczu7_0]
refresh_hw_device -update_hw_probes false [lindex [get_hw_devices xczu7_0] 0]
current_hw_device [get_hw_devices arm_dap_1]
refresh_hw_device -update_hw_probes false [lindex [get_hw_devices arm_dap_1] 0]
current_hw_device [get_hw_devices xczu7_0]
set_property PROBES.FILE {} [get_hw_devices xczu7_0]
set_property FULL_PROBES.FILE {} [get_hw_devices xczu7_0]
set_property PROGRAM.FILE {/home/dan/ibex/isolde/lca_system/fpga/vivado/aida-zcu104/aida-zcu104.runs/impl_1/xilinx_aida.bit} [get_hw_devices xczu7_0]
program_hw_devices [get_hw_devices xczu7_0]
program_hw_devices: Time (s): cpu = 00:00:11 ; elapsed = 00:00:11 . Memory (MB): peak = 7836.016 ; gain = 0.000 ; free physical = 13202 ; free virtual = 30231
refresh_hw_device [lindex [get_hw_devices xczu7_0] 0]