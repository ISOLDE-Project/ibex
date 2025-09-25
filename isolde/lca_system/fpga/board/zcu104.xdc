# Copyleft ISOLDE 2025

# 300MHZ clock
set_property PACKAGE_PIN AH18 [get_ports CLK_IN1_D_0_clk_p]
set_property PACKAGE_PIN AH17 [get_ports CLK_IN1_D_0_clk_n]
set_property IOSTANDARD DIFF_SSTL12 [get_ports CLK_IN1_D_0_clk_p]
set_property IOSTANDARD DIFF_SSTL12 [get_ports CLK_IN1_D_0_clk_n]

create_generated_clock -name ref_clk \
    -source [get_pins i_xilinx_clk_mngr/inst/mmcme4_adv_inst/CLKOUT0] \
    [get_pins bufg_inst/O]
## Reset
set_property -dict {PACKAGE_PIN M11 IOSTANDARD LVCMOS33} [get_ports pad_reset]

## PMOD 0
set_property -dict {PACKAGE_PIN G8 IOSTANDARD LVCMOS33} [get_ports pad_jtag_tms]
set_property -dict {PACKAGE_PIN H8 IOSTANDARD LVCMOS33} [get_ports pad_jtag_tdi]
set_property -dict {PACKAGE_PIN G7 IOSTANDARD LVCMOS33} [get_ports pad_jtag_tdo]
set_property -dict {PACKAGE_PIN H7 IOSTANDARD LVCMOS33} [get_ports pad_jtag_tck]
#set_property -dict {PACKAGE_PIN G6 IOSTANDARD LVCMOS33} [get_ports pad_pmod0_4]
#set_property -dict {PACKAGE_PIN H6 IOSTANDARD LVCMOS33} [get_ports pad_pmod0_5]
#set_property -dict {PACKAGE_PIN J6 IOSTANDARD LVCMOS33} [get_ports pad_pmod0_6]
#set_property -dict {PACKAGE_PIN J7 IOSTANDARD LVCMOS33} [get_ports pad_pmod0_7]

