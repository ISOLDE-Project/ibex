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
  // -------------------------------------------------------m
  localparam SIM_CYCLES=4000;
  localparam time CLK_HALF_PERIOD = 1ns;
  localparam time RST_TIME = 20*2*CLK_HALF_PERIOD;  // rst_time
  localparam time SIM_TIME = SIM_CYCLES*2*CLK_HALF_PERIOD;  // rst_time
  //localparam time RST_CYCLES = 10ns;  // rst_cycles (in time units, not clock cycles)
 

  // -------------------------------------------------------
  //  DUT signals
  // -------------------------------------------------------
  logic clk_i = 1'b0;
  logic rst_ni = 1'b0;
 

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
  //  DUT instantiation
  // -------------------------------------------------------
  aida_tb i_dut (
      .clk_i         (clk_i),
      .rst_ni        (rst_ni)
  );

`ifdef VERBOSE_QUESTA_RUN 
always @(posedge clk_i) begin
  if (rst_ni && i_dut.i_aida_top.i_aida.i_ibex_top.instr_req_o && i_dut.i_aida_top.i_aida.i_ibex_top.instr_gnt_i)
    $display("[FETCH] @ t=%0t: PC=%h", $time, i_dut.i_aida_top.i_aida.i_ibex_top.instr_addr_o);
end
`endif
  // -------------------------------------------------------
  //  Simulation timeout guard (optional safety net)
  //  Remove or increase if your test runs longer
  // -------------------------------------------------------
  initial begin
    //#10_000_000ns;
    #(SIM_TIME);
    $display("[tb_top_questa] @ t=%0t: TIMEOUT — simulation limit reached.", $time);
    $finish;
  end

endmodule
