



namespace eval _tcl {
proc get_script_folder {} {
   set script_path [file normalize [info script]]
   set script_folder [file dirname $script_path]
   return $script_folder
}
}
variable script_folder
set script_folder [_tcl::get_script_folder]


cd  $script_folder 

set proj_dir  [ get_property DIRECTORY [current_project] ]
set proj_name [ get_property NAME [current_project] ]
set orig_proj_dir "[file normalize "$proj_dir"]"

set xci_file "$proj_dir/$proj_name.srcs/sources_1/ip/$proj_name/$proj_name.xci"
set tcl_file "$script_folder/$proj_name-ip.tcl"
puts [ format "%s -- %s" $proj_dir $xci_file ]
write_ip_tcl -force -no_ip_version [ get_ips $proj_name ] $tcl_file 
puts [ format "%s -- done" $tcl_file]
