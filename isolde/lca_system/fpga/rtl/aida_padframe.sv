// Copyleft 2025 ISOLDE

module aida_padframe
  import pkg_aida_padframe::*;
(
  output pad_domain_all_pads_static_connection_signals_pad2soc_t static_connection_signals_pad2soc,
  input  pad_domain_all_pads_static_connection_signals_soc2pad_t static_connection_signals_soc2pad,

  // Landing Pads
  //inout wire logic pad_pad_reset_n_pad,
  inout wire logic pad_jtag_tck,
  inout wire logic pad_jtag_trstn,
  inout wire logic pad_jtag_tms,
  inout wire logic pad_jtag_tdi,
  inout wire logic pad_jtag_tdo
  
  );

   // Pad instantiations

  //  pad_functional_pu i_pad_reset_n (
  //   .PAD(pad_pad_reset_n_pad),
  //   .OEN(~1'b0),
  //   .PEN(~1'b0),
  //   .I(1'b0),
  //   .O(static_connection_signals_pad2soc.rst_n)
  // );

   pad_functional_pu i_pad_jtag_tck (
    .PAD(pad_jtag_tck),
    .OEN(~1'b0),
    .PEN(~1'b0),
    .I(1'b0),
    .O(static_connection_signals_pad2soc.jtag_tck)
  );
   pad_functional_pu i_pad_jtag_trstn (
    .PAD(pad_jtag_trstn),
    .OEN(~1'b0),
    .PEN(~1'b0),
    .I(1'b0),
    .O(static_connection_signals_pad2soc.jtag_trstn)
  );
   pad_functional_pu i_pad_jtag_tms (
    .PAD(pad_jtag_tms),
    .OEN(~1'b0),
    .PEN(~1'b0),
    .I(1'b0),
    .O(static_connection_signals_pad2soc.jtag_tms)
  );
   pad_functional_pu i_pad_jtag_tdi (
    .PAD(pad_jtag_tdi),
    .OEN(~1'b0),
    .PEN(~1'b0),
    .I(1'b0),
    .O(static_connection_signals_pad2soc.jtag_tdi)
  );
   pad_functional_pu i_pad_jtag_tdo (
    .PAD(pad_jtag_tdo),
    .OEN(~1'b1),
    .PEN(~1'b0),
    .I(static_connection_signals_soc2pad.jtag_tdo),
    .O()
  );
  
endmodule : aida_padframe
