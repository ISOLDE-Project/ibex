`timescale 1ps / 1ps

// -----------------------------------------------------------------------------
// Testbench for xilinx_aida
// -----------------------------------------------------------------------------
module tb_xilinx_aida;

  // Clock & reset
  reg  clk_p;
  reg  clk_n;
  reg  pad_reset;

  // JTAG
  wire  pad_jtag_tck;
  wire  pad_jtag_tdi;
  wire  pad_jtag_tms;
  wire pad_jtag_tdo;

  // ---------------------------------------------------------------------------
  // DUT Instance
  // ---------------------------------------------------------------------------
  xilinx_aida dut (
      .CLK_IN1_D_0_clk_p(clk_p),
      .CLK_IN1_D_0_clk_n(clk_n),
      .pad_reset        (pad_reset),
      .pad_jtag_tck     (pad_jtag_tck),
      .pad_jtag_tdi     (pad_jtag_tdi),
      .pad_jtag_tdo     (pad_jtag_tdo),
      .pad_jtag_tms     (pad_jtag_tms)
  );

  // ---------------------------------------------------------------------------
  // Clock Generation (Differential clock input)
  // 100 MHz differential input clock 5000 ps period
  // 100 MHz differential input clock 1667 ps period 
  // ---------------------------------------------------------------------------
  initial begin
    clk_p = 1'b0;
    clk_n = 1'b1;
  end

  always #1667 begin
    clk_p = ~clk_p;
    clk_n = ~clk_n;
  end

  // ---------------------------------------------------------------------------
  // Reset stimulus
  // Active high reset pulse at startup
  // ---------------------------------------------------------------------------
  initial begin
    pad_reset = 1'b1;
    #100000;
    pad_reset = 1'b0;
  end

  // ---------------------------------------------------------------------------
  // JTAG stimulus (basic toggle, extend as needed)
  // ---------------------------------------------------------------------------
//   initial begin
//     pad_jtag_tck = 0;
//     pad_jtag_tdi = 0;
//     pad_jtag_tms = 0;

//     // Wait for reset deassertion
//     @(negedge pad_reset);
//     #200;

//     // Example JTAG toggling sequence
//     repeat (20) begin
//       #50 pad_jtag_tdi = $random;
//       pad_jtag_tms = $random;
//       pad_jtag_tck = 1;
//       #50 pad_jtag_tck = 0;
//     end

//     // Finish simulation
//     #1000000;
//     $finish;
//   end

  // ---------------------------------------------------------------------------
  // Waveform dump
  // ---------------------------------------------------------------------------
  initial begin
    $dumpfile("tb_xilinx_aida.vcd");
    $dumpvars(0, tb_xilinx_aida);
  end

endmodule
