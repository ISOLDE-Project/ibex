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
##
##   100.000 ns = 10 MHz constrained, comfortable for a JTAG-HS2 over the PMOD
##                header while OpenOCD runs at 6 MHz (`adapter speed 6000`).
##
set tck_period 100.000

create_clock -period $tck_period -name tck \
    -waveform [list 0.000 [expr {$tck_period / 2.0}]] [get_ports pad_jtag_tck]
set_input_jitter tck 1.000

## H7 is not a clock-capable pin, so the pad -> BUFGCE hop runs on general
## routing. 
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

##
## JTAG I/O timing budget ( TIMING-18)
##
## IEEE 1149.1 edge model, which is what both the Digilent JTAG-HS2 adapter and
## riscv-dbg's dmi_jtag implement:
##
##   * the adapter launches TDI/TMS on the FALLING edge of TCK; the TAP samples
##     them on the following RISING edge   -> -clock_fall on set_input_delay
##   * the TAP launches TDO from a negedge-TCK flop; the adapter samples it on
##     the following RISING edge           -> no -clock_fall on set_output_delay
##
## Budgets below are adapter clock-to-out + PMOD/cable flight time, deliberately
## generous: TCK is 200 ns here, so the available window is 150 ns either way and
## these numbers are nowhere near binding. Tighten only if TCK is ever raised.
##
set jtag_in_max   20.000 ;# adapter Tco(max) + board delay, TCK fall -> TDI/TMS valid
set jtag_in_min    1.000 ;# adapter Tco(min) + board delay (hold side)
set jtag_out_max  20.000 ;# adapter Tsu + board delay on TDO
set jtag_out_min  -5.000 ;# -adapter Th + board delay on TDO (hold side)

set_input_delay  -clock tck -clock_fall -max $jtag_in_max \
    [get_ports {pad_jtag_tdi pad_jtag_tms}]
set_input_delay  -clock tck -clock_fall -min $jtag_in_min \
    [get_ports {pad_jtag_tdi pad_jtag_tms}]

set_output_delay -clock tck -max $jtag_out_max [get_ports pad_jtag_tdo]
set_output_delay -clock tck -min $jtag_out_min [get_ports pad_jtag_tdo]

# NOTE: the create_clock above declares a 25% duty cycle (-waveform {0 50} on a
# 200 ns period). The real adapter drives ~50%, so the falling edge is modelled
# 50 ns early and the input path gets 150 ns instead of 100 ns. Harmless at
# 5 MHz; fix the waveform to {0.000 100.000} before raising TCK.

## 
## TIMING-9
## Unknown CDC Logic  
## One or more asynchronous Clock Domain Crossing has been detected between 2 clock
## domains through a set_false_path or a set_clock_groups 
## or set_max_delay -datapath_only constraint but no double-registers logic
##  synchronizer has been found on the side of the capture clock. 
## 
set_clock_groups -name async_sys_tck -asynchronous \
    -group [get_clocks clk_out1_xilinx_clk_mngr] \
    -group [get_clocks tck]


## UART TX
#
# FPGA_TXD → FT4232HL RXD ( Channel D) → USB → PC (virtual COM port)
#
# +-----------------------------------------+----------------------------+
# |                 FT4232H                 | XCZU7EV                    |
# +-------+----------+----------------------+-------+--------------------+
# | Pin # | Pin Name | ASYNC Serial (RS232) | Pin # | Net Name           |
# +-------+----------+----------------------+-------+--------------------+
# | 48    | DDBUS0   | TXD                  | A20   | UART2_TXD_FPGA_RXD |
# +-------+----------+----------------------+-------+--------------------+
# | 52    | DDBUS1   | RXD                  | C19   | UART2_RXD_FPGA_TXD |
# +-------+----------+----------------------+-------+--------------------+
# References:
# https://www.mouser.com/datasheet/2/903/ug1267-zcu104-eval-bd-1596428.pdf
# https://ftdichip.com/wp-content/uploads/2024/09/DS_FT4232H.pdf

set_property -dict {PACKAGE_PIN C19 IOSTANDARD LVCMOS18} [get_ports pad_uart_tx]