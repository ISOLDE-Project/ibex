source $::env(FPGA_DIR)/tcl/common.tcl

# detect target clock
if [info exists ::env(FC_CLK_PERIOD_NS)] {
    set FC_CLK_PERIOD_NS $::env(FC_CLK_PERIOD_NS)
} else {
    set FC_CLK_PERIOD_NS 10.000
}
if [info exists ::env(PER_CLK_PERIOD_NS)] {
    set PER_CLK_PERIOD_NS $::env(PER_CLK_PERIOD_NS)
} else {
    set PER_CLK_PERIOD_NS 20.000
}


set FC_CLK_FREQ_MHZ [expr 1000 / $FC_CLK_PERIOD_NS]
set PER_CLK_FREQ_MHZ [expr 1000 / $PER_CLK_PERIOD_NS]


create_ip -name clk_wiz -vendor xilinx.com -library ip -module_name $ipName

# User Parameters
set_property -dict [list \
  CONFIG.CLKIN1_JITTER_PS {33.330000000000005} \
  CONFIG.CLKOUT1_JITTER {106.018} \
  CONFIG.CLKOUT1_PHASE_ERROR {77.836} \
  CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {80.0} \
  CONFIG.CLKOUT2_JITTER {116.415} \
  CONFIG.CLKOUT2_PHASE_ERROR {77.836} \
  CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {100.000} \
  CONFIG.CLKOUT2_USED {false} \
  CONFIG.CLK_IN1_BOARD_INTERFACE {clk_300mhz} \
  CONFIG.MMCM_CLKFBOUT_MULT_F {4.000} \
  CONFIG.MMCM_CLKIN1_PERIOD {3.333} \
  CONFIG.MMCM_CLKIN2_PERIOD {10.0} \
  CONFIG.MMCM_CLKOUT0_DIVIDE_F {15.000} \
  CONFIG.MMCM_CLKOUT1_DIVIDE {1} \
  CONFIG.MMCM_DIVCLK_DIVIDE {1} \
  CONFIG.NUM_OUT_CLKS {1} \
  CONFIG.PRIM_IN_FREQ {300.000} \
  CONFIG.PRIM_SOURCE {Differential_clock_capable_pin} \
  CONFIG.RESET_BOARD_INTERFACE {reset} \
  CONFIG.RESET_PORT {reset} \
  CONFIG.RESET_TYPE {ACTIVE_HIGH} \
  CONFIG.USE_LOCKED {true} \
] [get_ips $ipName]

create_ip_run [get_ips $ipName]
launch_run -jobs 8 ${ipName}_synth_1
wait_on_run ${ipName}_synth_1
