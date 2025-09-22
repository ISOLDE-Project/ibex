// Copyleft ISOLDE 2025


module xilinx_aida (
    input wire ref_clk_p,
    input wire ref_clk_n,
    input wire pad_reset,
    //JTAG
    inout wire pad_jtag_tck,
    inout wire pad_jtag_tdi,
    inout wire pad_jtag_tdo,
    inout wire pad_jtag_tms
);



  wire ref_clk;


  //Differential to single ended clock conversion
  IBUFGDS #(
      .IOSTANDARD("LVDS"),
      .DIFF_TERM("FALSE"),
      .IBUF_LOW_PWR("FALSE")
  ) i_sysclk_iobuf (
      .I (ref_clk_p),
      .IB(ref_clk_n),
      .O (ref_clk)
  );
  aida_top #() i_aida_top (
      .clk_i(ref_clk),
      .rst_ni(pad_reset),
      .fetch_enable_i(1'b1),
      // JTAG signals 
      .jtag_tck_i(pad_jtag_tck),
      .jtag_trst_ni(1'b1),
      .jtag_tms_i(pad_jtag_tms),
      .jtag_tdi_i(pad_jtag_tdi),
      .jtag_tdo_o(pad_jtag_tdo)
  );

endmodule
