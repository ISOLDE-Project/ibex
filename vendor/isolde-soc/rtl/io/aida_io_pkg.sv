package aida_io_pkg;
  //
  // // Outputs from the SoC
  typedef struct packed {
    //UART TX output`
    logic uart_tx_o;

  } aida_pads_o_t;

`ifdef TARGET_VERILATOR
  parameter int unsigned UART_CLOCK_FREQ = 115_200;  // sys_clk_i value in Hz
  parameter int unsigned UART_BAUD_RATE = 115_200;

`else
  parameter int unsigned UART_CLOCK_FREQ = 10_000_000;  // sys_clk_i value in Hz
  parameter int unsigned UART_BAUD_RATE = 115_200;

`endif
endpackage : aida_io_pkg


