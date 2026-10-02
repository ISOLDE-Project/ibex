# Vivado FPGA programming helper.
#
# Environment:
#   ROOT_DIR=/home/dan/ibex
#
# Usage from Vivado Tcl console:
#   source program_fpga.tcl
#   program_fpga
#
# By default xilinx.cfg is expected next to this Tcl file. An explicit cfg
# path can also be passed:
#   program_fpga /path/to/xilinx.cfg

set ::program_fpga_script_dir [file dirname [file normalize [info script]]]

proc program_fpga {{cfg_file ""}} {
    # Resolve configuration file.
    if {$cfg_file eq ""} {
        set cfg_file [file join $::program_fpga_script_dir ../board/xilinx.cfg]
    } else {
        set cfg_file [file normalize $cfg_file]
    }

    if {![file isfile $cfg_file]} {
        error "xilinx.cfg not found: $cfg_file"
    }

    # ROOT_DIR must be inherited by Vivado from the environment.
    if {![info exists ::env(ROOT_DIR)] || $::env(ROOT_DIR) eq ""} {
        error "ROOT_DIR is not set. Example: export ROOT_DIR=/home/dan/ibex"
    }
    set root_dir [file normalize $::env(ROOT_DIR)]

    # xilinx.cfg defines, among other things:
    #   project
    #   _top_module_
    source $cfg_file

    if {![info exists project] || $project eq ""} {
        error "Configuration '$cfg_file' does not define 'project'"
    }
    if {![info exists _top_module_] || ${_top_module_} eq ""} {
        error "Configuration '$cfg_file' does not define '_top_module_'"
    }

    # Example with the supplied xilinx.cfg:
    #   /home/dan/ibex/isolde/system/fpga/vivado/aida-zcu104/
    #       aida-zcu104.runs/impl_1/xilinx_aida.bit
    set bit_file [file join \
        $root_dir \
        isolde system fpga vivado \
        $project \
        "${project}.runs" \
        impl_1 \
        "${_top_module_}.bit"]

    if {![file isfile $bit_file]} {
        error "Bitstream not found: $bit_file"
    }

    set hw_target_pattern "*/xilinx_tcf/Xilinx/29390A"
    set jtag_frequency 15000000

    puts "Programming FPGA"
    puts "  config  : $cfg_file"
    puts "  project : $project"
    puts "  bitfile : $bit_file"

    open_hw_manager
    connect_hw_server -url localhost:3121 -allow_non_jtag

    set hw_target [lindex [get_hw_targets -quiet $hw_target_pattern] 0]
    if {$hw_target eq ""} {
        error "Hardware target not found: $hw_target_pattern"
    }

    current_hw_target $hw_target
    set_property PARAM.FREQUENCY $jtag_frequency $hw_target
    open_hw_target

    set fpga_device [lindex [get_hw_devices -quiet xczu7_0] 0]
    if {$fpga_device eq ""} {
        error "FPGA hardware device 'xczu7_0' not found"
    }

    current_hw_device $fpga_device
    refresh_hw_device -update_hw_probes false $fpga_device

    # Refresh the ARM DAP as in the captured Vivado console sequence, if present.
    set arm_dap [lindex [get_hw_devices -quiet arm_dap_1] 0]
    if {$arm_dap ne ""} {
        current_hw_device $arm_dap
        refresh_hw_device -update_hw_probes false $arm_dap
    }

    current_hw_device $fpga_device
    set_property PROBES.FILE {} $fpga_device
    set_property FULL_PROBES.FILE {} $fpga_device
    set_property PROGRAM.FILE $bit_file $fpga_device

    program_hw_devices $fpga_device
    refresh_hw_device $fpga_device
    disconnect_hw_server localhost:3121
    puts "FPGA programmed successfully: $bit_file"
}

# Batch-mode entry point.
#
# This keeps interactive usage unchanged:
#   source ./tcl/program_fpga.tcl
#   program_fpga ./board/xilinx.cfg
#
# And enables:
#   vivado -mode batch -source ./tcl/program_fpga.tcl -tclargs ./board/xilinx.cfg
#
# Vivado places arguments following -tclargs in ::argv.
if {[info exists ::argv] && [llength $::argv] > 0} {
    if {[llength $::argv] != 1} {
        error "Usage: program_fpga.tcl <xilinx.cfg>"
    }
    program_fpga [lindex $::argv 0]
}