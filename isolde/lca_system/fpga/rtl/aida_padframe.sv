// Copyleft 2025 ISOLDE

module aida_padframe (
    output jtag_pkg::jtag_req_t pad2soc_jtag_o,
    input jtag_pkg::jtag_rsp_t soc2pad_jtag_i,
    input wire internal_jtag_trstn,
    // Landing Pads
    input wire pad_jtag_tms,
    input wire pad_jtag_tdi,
    inout wire pad_jtag_tdo,
    input wire pad_jtag_tck

);

  assign pad2soc_jtag_o.trst_n = internal_jtag_trstn;
  // ------------------------------------------------------------------------  
  // Pad instantiations
  // ------------------------------------------------------------------------

  // ------------------------------------------------------------------------
  // TMS : Test Mode Select Input
  //  - Uses IBUF with PULLUP so TAP resets when idle
  // ------------------------------------------------------------------------
  (*  PULLUP = "TRUE" *)
  wire tms_ibuf_out;

  IBUF tms_ibuf_inst (
      .I(pad_jtag_tms),
      .O(tms_ibuf_out)
  );
  assign pad2soc_jtag_o.tms = tms_ibuf_out;

  // ------------------------------------------------------------------------
  // TDI : Test Data Input
  //  - Uses IBUF with PULLUP to avoid floating input
  // ------------------------------------------------------------------------
  (*  PULLUP = "TRUE" *)
  wire tdi_ibuf_out;

  IBUF tdi_ibuf_inst (
      .I(pad_jtag_tdi),
      .O(tdi_ibuf_out)
  );
  assign pad2soc_jtag_o.tdi = tdi_ibuf_out;



  // ------------------------------------------------------------------------
  // TDO : Test Data Output (bidirectional)
  //  - Uses IOBUF
  //  - No internal pull-up (recommended external 10 kΩ)
  // ------------------------------------------------------------------------
  (* IOSTANDARD = "LVCMOS33" *)
  IOBUF tdo_iobuf_inst (
      .I (soc2pad_jtag_i.tdo),     // internal signal to drive TDO
      .O (),                       // not used internally
      .IO(pad_jtag_tdo),           // physical FPGA pin
      .T (~soc2pad_jtag_i.tdo_oe)  // tri-state control
  );

  // ------------------------------------------------------------------------
  // TCK : JTAG Test Clock Input
  //  - Uses IBUF with PULLDOWN to keep low when master disconnected
  // ------------------------------------------------------------------------
  // TCK
  (*  PULLDOWN = "TRUE" *)
  wire tck_ibuf_out;
  IBUF tck_ibuf_inst (
      .I(pad_jtag_tck),
      .O(tck_ibuf_out)
  );
  assign pad2soc_jtag_o.tck = tck_ibuf_out;
endmodule : aida_padframe
