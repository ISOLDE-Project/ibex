############################################################
# rv_top Backend Constraints
# Target PDK: IHP SG13G2
############################################################

#############################
## Driving Cells and Loads ##
#############################

# Model realistic external load
# CROC assumes 2 pads + small trace → reuse that assumption
set_load [expr 2 * 5.0 + 5.0] [all_outputs]

# Model signals entering macro from IO pad drivers
set_driving_cell [all_inputs] -lib_cell sg13g2_IOPadOut16mA -pin pad


##################
## Input Clock ##
##################
puts "Clocks..."

# Target CPU frequency (CROC default style)
# 12.5 ns → 80 MHz
set TCK_SYS 12.5

create_clock -name clk_sys -period $TCK_SYS [get_ports clk_i]


##################################
## Clock Uncertainty & Slew ##
##################################

set_clock_uncertainty 0.1 [all_clocks]
set_clock_transition  0.2 [all_clocks]


#############
## Reset ##
#############
puts "Reset..."

# Reset should settle quickly
set_input_delay -max [expr $TCK_SYS * 0.10] [get_ports rst_ni]

# Reset is async → disable hold fixing
set_false_path -hold -from [get_ports rst_ni]

# Reset must reach sequential logic within 1 cycle
set_max_delay $TCK_SYS -from [get_ports rst_ni]


#############################
## Instruction Interface ##
#############################
puts "Instruction Bus..."

set INSTR_INPUTS [get_ports {
    instr_gnt_i
    instr_rvalid_i
    instr_rdata_i*
    instr_rdata_intg_i*
    instr_err_i
}]

set INSTR_OUTPUTS [get_ports {
    instr_req_o
    instr_addr_o*
}]

set_input_delay  -min -add_delay -clock clk_sys [expr $TCK_SYS * 0.10] $INSTR_INPUTS
set_input_delay  -max -add_delay -clock clk_sys [expr $TCK_SYS * 0.30] $INSTR_INPUTS

set_output_delay -min -add_delay -clock clk_sys [expr $TCK_SYS * 0.10] $INSTR_OUTPUTS
set_output_delay -max -add_delay -clock clk_sys [expr $TCK_SYS * 0.30] $INSTR_OUTPUTS


#############################
## Data Interface ##
#############################
puts "Data Bus..."

set DATA_INPUTS [get_ports {
    data_gnt_i
    data_rvalid_i
    data_rdata_i*
    data_rdata_intg_i*
    data_err_i
}]

set DATA_OUTPUTS [get_ports {
    data_req_o
    data_we_o
    data_be_o*
    data_addr_o*
    data_wdata_o*
   data_wdata_intg_o*

}]

set_input_delay  -min -add_delay -clock clk_sys [expr $TCK_SYS * 0.10] $DATA_INPUTS
set_input_delay  -max -add_delay -clock clk_sys [expr $TCK_SYS * 0.30] $DATA_INPUTS

set_output_delay -min -add_delay -clock clk_sys [expr $TCK_SYS * 0.10] $DATA_OUTPUTS
set_output_delay -max -add_delay -clock clk_sys [expr $TCK_SYS * 0.30] $DATA_OUTPUTS


#############################
## Control Inputs ##
#############################
puts "Control..."

set CTRL_INPUTS [get_ports {
    irq_software_i
    debug_req_i
    fetch_enable_i*
}]

set_input_delay  -min -add_delay -clock clk_sys [expr $TCK_SYS * 0.10] $CTRL_INPUTS
set_input_delay  -max -add_delay -clock clk_sys [expr $TCK_SYS * 0.30] $CTRL_INPUTS


#############################
## Status Outputs ##
#############################
puts "Status..."

set STATUS_OUTPUTS [get_ports {
    alert_minor_o
    alert_major_internal_o
    alert_major_bus_o
    core_sleep_o
}]

set_output_delay -min -add_delay -clock clk_sys [expr $TCK_SYS * 0.10] $STATUS_OUTPUTS
set_output_delay -max -add_delay -clock clk_sys [expr $TCK_SYS * 0.30] $STATUS_OUTPUTS

############################################################
# Fix Ibex clock gating timing
############################################################

set_clock_gating_check -setup 0.3 -hold 0.1 [all_clocks]
set_disable_timing [get_pins -hierarchical */SCE]