// Copyleft ISOLDE 2025
// Questa/ModelSim-compatible top-level stimulus wrapper
// Functional equivalent of tb_top_verilator.cpp

`timescale 1ns / 1ps

module tb_top_questa;

  // -------------------------------------------------------
  //  Clock & reset generation parameters
  //  Matches cpp: rst_time=20, rst_cycles=10 (time units)
  //  Clock toggles every 1 time unit → period = 2 units
  //  We use 1ns half-period to match "timeInc(1)" steps
  // -------------------------------------------------------
  localparam time CLK_HALF_PERIOD = 1ns;
  localparam time RST_TIME = 20ns;  // rst_time
  localparam time RST_CYCLES = 10ns;  // rst_cycles (in time units, not clock cycles)
  localparam time FETCH_EN_TIME = 100ns;  // fetch_enable_i goes high after t=100

  // -------------------------------------------------------
  //  DUT signals
  // -------------------------------------------------------
  logic clk_i = 1'b0;
  logic rst_ni = 1'b0;
  logic fetch_enable_i = 1'b0;

  // -------------------------------------------------------
  //  Clock generation — toggles every 1ns, as in the cpp
  //  (contextp->timeInc(1), clk_i ^= 1)
  // -------------------------------------------------------
  always #(CLK_HALF_PERIOD) clk_i = ~clk_i;

  // -------------------------------------------------------
  //  Reset sequence — mirrors dut_reset()
  //
  //  C++ logic (evaluated every time step):
  //    t <= rst_time                        → rst_ni = 0
  //    rst_time  < t < rst_time+rst_cycles  → rst_ni = 1
  //    rst_time+rst_cycles < t < rst_time+2*rst_cycles → rst_ni = 0
  //    t > rst_time+2*rst_cycles            → rst_ni = 1
  // -------------------------------------------------------
  initial begin
    rst_ni = 1'b0;

    // Phase 1: deasserted until RST_TIME
    #(RST_TIME);

    // // Phase 2: assert high for RST_CYCLES
    // rst_ni = 1'b1;
    // #(RST_CYCLES);

    // // Phase 3: pull low again for RST_CYCLES
    // rst_ni = 1'b0;
    // #(RST_CYCLES);

    // Phase 4: final release — stays high
    rst_ni = 1'b1;
  end

  // -------------------------------------------------------
  //  Fetch enable — mirrors dut_set_fetch_en()
  //  fetch_enable_i = 0 until t > 100, then = 1
  // -------------------------------------------------------
  initial begin
    // fetch_enable_i = 1'b0;
    // #(FETCH_EN_TIME);
    fetch_enable_i = 1'b1;
  end

  // -------------------------------------------------------
  //  DUT instantiation
  // -------------------------------------------------------
  tb_system i_dut (
      .clk_i         (clk_i),
      .rst_ni        (rst_ni),
      .fetch_enable_i(fetch_enable_i)
  );

 

  // -------------------------------------------------------
  //  Simulation timeout guard (optional safety net)
  //  Remove or increase if your test runs longer
  // -------------------------------------------------------
  initial begin
    #10_000_000ns;
    $display("[TB_TOP] @ t=%0t: TIMEOUT — simulation limit reached.", $time);
    $finish;
  end

endmodule
