################################################################
# configure board
source ./board/xilinx.cfg
################################################################


if { ![info exists ::project] } {
    puts "ERROR: Project name is not defined"
    exit 1
}



set scripts_vivado_version 2022.1
set current_vivado_version [version -short]

if { [string first $scripts_vivado_version $current_vivado_version] == -1 } {
  puts "CRITICAL WARNING: This script was generated for Vivado $scripts_vivado_version but is running in $current_vivado_version"
}

namespace eval _tcl {
proc get_script_folder {} {
   set script_path [file normalize [info script]]
   set script_folder [file dirname $script_path]
   return $script_folder
}
}

# Set the reference directory for source file relative paths (by default the value is script directory path)
variable origin_dir
set origin_dir [_tcl::get_script_folder]




# Set the directory path for the original project from where this script was exported
#set orig_proj_dir "[file normalize "$origin_dir/resizer"]"

# Create project
set list_projs [get_projects -quiet]
if { $list_projs eq "" } {
    create_project $project  ./vivado/$project  -part $part  -force
} else {
    puts "Error: ./vivado/$project not an empty folder"
    return 1
}

# Set project properties
set obj [current_project]
set_property -name "board_part"         -value ${_board_part_}        -objects $obj
set_property -name "platform.board_id"  -value ${_platform_board_id_} -objects $obj

source ./vivado_synth.tcl

# Get current include_dirs from the active fileset
set current_dirs [get_property include_dirs [current_fileset]]

# Prepend ibex_include_dirs to the current ones
set new_include_dirs [concat $ibex_include_dirs $current_dirs]

# Update the property
set_property include_dirs $new_include_dirs [current_fileset]

set_property top ibex_top [current_fileset]
#set_property top  [current_fileset]
set_property source_mgmt_mode None [current_project]
update_compile_order -fileset sources_1
