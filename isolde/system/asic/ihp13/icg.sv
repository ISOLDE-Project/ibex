// Copyleft 2026 ISOLDE


module prim_generic_clock_gating #(
    parameter bit NoFpgaGate = 1'b0,  // this parameter has no function in generic
    parameter bit FpgaBufGlobal = 1'b1  // this parameter has no function in generic
) (
    input  logic clk_i,
    input  logic en_i,
    input  logic test_en_i,
    output logic clk_o
);


  (* keep *) (* dont_touch = "true" *)
  sg13g2_slgcp_1 i_clkgate (
      .GATE(en_i),
      .SCE (test_en_i),
      .CLK (clk_i),
      .GCLK(clk_o)
  );

endmodule
