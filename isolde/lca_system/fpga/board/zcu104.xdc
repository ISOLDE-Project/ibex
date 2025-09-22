# Copyleft ISOLDE 2025

#Create constraint for the clock input of the zcu104 board
create_clock -period 8.000 -name ref_clk [get_ports ref_clk_p]
#set_property CLOCK_DEDICATED_ROUTE ANY_CMT_COLUMN [get_nets ref_clk]
set_property CLOCK_DEDICATED_ROUTE ANY_CMT_COLUMN [get_nets -of [get_ports ref_clk_p]]
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets pad_reset_IBUF_inst/O]

## Sys clock
set_property -dict {PACKAGE_PIN E23 IOSTANDARD LVDS} [get_ports ref_clk_n]
set_property -dict {PACKAGE_PIN F23 IOSTANDARD LVDS} [get_ports ref_clk_p]

## Reset
set_property -dict {PACKAGE_PIN M11 IOSTANDARD LVCMOS33} [get_ports pad_reset]

## PMOD 0
set_property -dict {PACKAGE_PIN G8 IOSTANDARD LVCMOS33} [get_ports pad_jtag_tms]
set_property -dict {PACKAGE_PIN H8 IOSTANDARD LVCMOS33} [get_ports pad_jtag_tdi]
set_property -dict {PACKAGE_PIN G7 IOSTANDARD LVCMOS33} [get_ports pad_jtag_tdo]
set_property -dict {PACKAGE_PIN H7 IOSTANDARD LVCMOS33} [get_ports pad_jtag_tck]
set_property -dict {PACKAGE_PIN G6 IOSTANDARD LVCMOS33} [get_ports pad_pmod0_4]
set_property -dict {PACKAGE_PIN H6 IOSTANDARD LVCMOS33} [get_ports pad_pmod0_5]
set_property -dict {PACKAGE_PIN J6 IOSTANDARD LVCMOS33} [get_ports pad_pmod0_6]
set_property -dict {PACKAGE_PIN J7 IOSTANDARD LVCMOS33} [get_ports pad_pmod0_7]