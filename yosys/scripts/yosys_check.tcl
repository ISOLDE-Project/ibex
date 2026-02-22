# Copyright (c) 2022 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Authors:
# - Philippe Sauter <phsauter@iis.ee.ethz.ch>

# This flows assumes it is beign executed in the yosys/ directory
# but just to be sure, we go there
if {[info script] ne ""} {
    cd "[file dirname [info script]]/../"
}

# Configuration variables are in yosys_commono
# get environment variables
source scripts/yosys_common.tcl

# ABC logic optimization script
set abc_script [processAbcScript scripts/abc-opt.script]

# read liberty files and prepare some variables
source scripts/init_tech.tcl

yosys plugin -i slang.so
# default from yosys_common.tcl: top_design=croc_chip; sv_flist=../croc.flist
yosys read_slang -D BootROMEnable=$BootROMEnable  --top $top_design -F $sv_flist \
        --compat-mode --keep-hierarchy \
        --allow-use-before-declare --ignore-unknown-modules 
         

# preserve hierarchy of selected modules/instances
# 't' means type as in select all instances of this type/module
# yosys-slang uniquifies all modules with the naming scheme:
# <module-name>$<instance-name> -> match for t:<module-name>$$
# yosys setattr -set keep_hierarchy 1 "t:croc_soc$*"
# yosys setattr -set keep_hierarchy 1 "t:croc_domain$*"
# yosys setattr -set keep_hierarchy 1 "t:user_domain$*"
# yosys setattr -set keep_hierarchy 1 "t:core_wrap$*"
# yosys setattr -set keep_hierarchy 1 "t:cve2_register_file_ff$*"
# yosys setattr -set keep_hierarchy 1 "t:cve2_cs_registers$*"
# yosys setattr -set keep_hierarchy 1 "t:dmi_jtag$*"
# yosys setattr -set keep_hierarchy 1 "t:dm_top$*"
# yosys setattr -set keep_hierarchy 1 "t:gpio$*"
# yosys setattr -set keep_hierarchy 1 "t:timer_unit$*"
# yosys setattr -set keep_hierarchy 1 "t:reg_uart_wrap$*"
# yosys setattr -set keep_hierarchy 1 "t:soc_ctrl_reg_top$*"
# yosys setattr -set keep_hierarchy 1 "t:tc_clk*$*"
# yosys setattr -set keep_hierarchy 1 "t:tc_sram_impl$*"
# yosys setattr -set keep_hierarchy 1 "t:cdc_*$*"



# blackbox modules (applies the *blackbox* attribute)
# yosys blackbox "t:tc_sram_blackbox$*"

# map dont_touch attribute commonly applied to output-nets of async regs to keep
yosys attrmap -rename dont_touch keep
# copy the keep attribute to their driving cells (retain on net for debugging)
yosys attrmvcp -copy -attr keep


# -----------------------------------------------------------------------------
# this section heavily borrows from the yosys synth command:
# synth - check
yosys hierarchy -top $top_design 
yosys check
yosys proc
yosys opt -full
yosys check
yosys flatten
yosys write_verilog -noattr -noexpr -nohex -nodec ${out_dir}/${top_design}_yosys.v 
#yosys stat
