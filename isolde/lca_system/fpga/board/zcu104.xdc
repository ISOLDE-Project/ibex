# Copyleft ISOLDE 2025

## 300MHZ clock
set_property PACKAGE_PIN AH18 [get_ports CLK_IN1_D_0_clk_p]
set_property PACKAGE_PIN AH17 [get_ports CLK_IN1_D_0_clk_n]
set_property IOSTANDARD DIFF_SSTL12 [get_ports CLK_IN1_D_0_clk_p]
set_property IOSTANDARD DIFF_SSTL12 [get_ports CLK_IN1_D_0_clk_n]


## Reset
#set_property -dict {PACKAGE_PIN M11 IOSTANDARD LVCMOS33} [get_ports pad_reset]
## Active High SW18, a.k.a GPIO_PB_SW3
set_property -dict {PACKAGE_PIN C3  IOSTANDARD LVCMOS33} [get_ports pad_reset]  

## GPIO LEDs (Active High)
set_property PACKAGE_PIN D5 [get_ports GPIO_LED_0]
set_property PACKAGE_PIN D6 [get_ports GPIO_LED_1]
set_property PACKAGE_PIN A5 [get_ports GPIO_LED_2]
set_property PACKAGE_PIN B5 [get_ports GPIO_LED_3]

set_property IOSTANDARD LVCMOS33 [get_ports GPIO_LED_0]
set_property IOSTANDARD LVCMOS33 [get_ports GPIO_LED_1]
set_property IOSTANDARD LVCMOS33 [get_ports GPIO_LED_2]
set_property IOSTANDARD LVCMOS33 [get_ports GPIO_LED_3]

## Pushbuttons
#set_property -dict {PACKAGE_PIN B4 IOSTANDARD LVCMOS33} [get_ports GPIO_PB_SW0]
#set_property -dict {PACKAGE_PIN C4 IOSTANDARD LVCMOS33} [get_ports GPIO_PB_SW1]
#set_property -dict {PACKAGE_PIN B3 IOSTANDARD LVCMOS33} [get_ports GPIO_PB_SW2]
#

## JTAG
create_clock -period 200.000 -name tck -waveform {0.000 50.000} [get_ports pad_jtag_tck]
set_input_jitter tck 1.000
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets pad_jtag_tck_IBUF_inst/O]

## PMOD 0
set_property -dict {PACKAGE_PIN G8 IOSTANDARD LVCMOS33} [get_ports pad_jtag_tms]
set_property -dict {PACKAGE_PIN H8 IOSTANDARD LVCMOS33} [get_ports pad_jtag_tdi]
set_property -dict {PACKAGE_PIN G7 IOSTANDARD LVCMOS33} [get_ports pad_jtag_tdo]
set_property -dict {PACKAGE_PIN H7 IOSTANDARD LVCMOS33} [get_ports pad_jtag_tck]
#set_property -dict {PACKAGE_PIN G6 IOSTANDARD LVCMOS33} [get_ports pad_pmod0_4]
#set_property -dict {PACKAGE_PIN H6 IOSTANDARD LVCMOS33} [get_ports pad_pmod0_5]
#set_property -dict {PACKAGE_PIN J6 IOSTANDARD LVCMOS33} [get_ports pad_pmod0_6]
#set_property -dict {PACKAGE_PIN J7 IOSTANDARD LVCMOS33} [get_ports pad_pmod0_7]

set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets pad_jtag_tck_IBUF_inst/O] 

# Declare that clk_out1_xilinx_clk_mngr and tck are asynchronous
set_false_path -from [get_clocks clk_out1_xilinx_clk_mngr] -to [get_clocks tck]
set_false_path -from [get_clocks tck] -to [get_clocks clk_out1_xilinx_clk_mngr]
