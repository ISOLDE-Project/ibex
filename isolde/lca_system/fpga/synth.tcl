source ./board/xilinx.cfg

open_project ./vivado/$project/$project.xpr
reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_runs synth_1
close_project
