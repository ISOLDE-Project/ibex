// Copyleft ISOLDE 2025



module xilinx_aida (
    input wire CLK_IN1_D_0_clk_p,
    input wire CLK_IN1_D_0_clk_n,
    input wire pad_reset,
    //JTAG
    inout wire pad_jtag_tck,
    inout wire pad_jtag_tdi,
    inout wire pad_jtag_tdo,
    inout wire pad_jtag_tms
);



  wire ref_clk;

 xilinx_clk_mngr i_xilinx_clk_mngr 
 (
  // Clock out ports
  .clk_out1(ref_clk),
  // Status and control signals
  .reset(pad_reset),
 // Clock in ports
  .clk_in1_p(CLK_IN1_D_0_clk_p),
  . clk_in1_n(CLK_IN1_D_0_clk_n)
 );


  aida_top #() i_aida_top (
      .clk_i(ref_clk),
      .rst_ni(1'b1),
      .fetch_enable_i(1'b1),
      // JTAG signals 
      .jtag_tck_i(pad_jtag_tck),
      .jtag_trst_ni(1'b1),
      .jtag_tms_i(pad_jtag_tms),
      .jtag_tdi_i(pad_jtag_tdi),
      .jtag_tdo_o(pad_jtag_tdo)
  );

endmodule
