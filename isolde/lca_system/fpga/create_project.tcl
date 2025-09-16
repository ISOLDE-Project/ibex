################################################################
# configure board
source ./board/xilinx.cfg
################################################################


if { ![info exists ::project] } {
  puts "project name is not defined"
  exit(0)
}



set scripts_vivado_version 2022.1
set current_vivado_version [version -short]

if { [string first $scripts_vivado_version $current_vivado_version] == -1 } {
  puts ""
  catch { "CRITICAL WARNING: This script was generated using Vivado <$scripts_vivado_version> and is being run in <$current_vivado_version> of Vivado"}
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
#set_property top top_isolde_ip [current_fileset]
#set_property top snitch_cluster_wrapper [current_fileset]
update_compile_order -fileset sources_1
