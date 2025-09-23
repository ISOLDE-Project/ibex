source ./board/xilinx.cfg

open_project ./vivado/$project/$project.xpr

open_run synth_1
report_utilization
# Query all URAM sites in the device
puts "URAM count: [llength [get_sites URAM*]]"

# Query all BRAM (RAMB18/36) sites in the device
puts "RAMB18 count: [llength [get_sites RAMB18*]]"
puts "RAMB36 count: [llength [get_sites RAMB36*]]"

#list_property [get_parts xczu7ev-ffvc1156-2-e]