// Copyleft ISOLDE 2025

module xilinx_aida 
import pkg_aida_padframe::*;
  (
    input  wire CLK_IN1_D_0_clk_p,
    input  wire CLK_IN1_D_0_clk_n,
    input  wire pad_reset,

    // JTAG
    inout  wire pad_jtag_tck,
    inout  wire pad_jtag_tdi,
    inout  wire pad_jtag_tdo,
    inout  wire pad_jtag_tms
);

  wire            jtag_tck_o;
  wire            jtag_trst_no;
  wire            jtag_tms_o;
  wire            jtag_tdi_o;
  wire            jtag_tdo_i;
  static_connection_signals_soc2pad_t s_static_connections_soc2pad;
  static_connection_signals_pad2soc_t s_static_connections_pad2soc;
  // Static Connections

  // JTAG
  assign jtag_tck_o   = s_static_connections_pad2soc.all_pads.jtag_tck;
  assign jtag_tdi_o   = s_static_connections_pad2soc.all_pads.jtag_tdi;
  assign jtag_tms_o   = s_static_connections_pad2soc.all_pads.jtag_tms;
  assign jtag_trst_no = s_static_connections_pad2soc.all_pads.jtag_trstn;
  assign s_static_connections_soc2pad.all_pads.jtag_tdo = jtag_tdo_i;
  // Internal clock and reset signals
  wire ref_clk;
  wire sys_mb_reset;
  wire locked_sig;

  wire [0:0] sys_bus_struct_reset;
  wire [0:0] sys_peripheral_reset;
  wire [0:0] sys_interconnect_aresetn;
  wire [0:0] sys_peripheral_aresetn;

//
aida_padframe i_aida_padframe(
  .static_connection_signals_pad2soc(s_static_connections_pad2soc),
  .static_connection_signals_soc2pad(s_static_connections_soc2pad),
  .pad_jtag_tck(pad_jtag_tck),
  .pad_jtag_trstn(1'b1),
  .pad_jtag_tms(pad_jtag_tms),
  .pad_jtag_tdi(pad_jtag_tdi),
  .pad_jtag_tdo(pad_jtag_tdo)
);

  wire jtag_tck_gated;

  BUFGCE i_jtag_clk_gate
    (
      .I(jtag_tck_o),
      .CE(1'b1),
      .O(jtag_tck_gated)
     );
 // assign jtag_tck_gated = jtag_tck_o;

  // Clock manager instance (generates ref_clk)
  xilinx_clk_mngr i_xilinx_clk_mngr (
    // Clock out ports
    .clk_out1(ref_clk),
    // Status and control signals
    .reset(pad_reset),
    .locked(locked_sig),
    // Clock in ports
    .clk_in1_p(CLK_IN1_D_0_clk_p),
    .clk_in1_n(CLK_IN1_D_0_clk_n)
  );



  // Reset synchronizer (Xilinx proc_sys_reset)
  xilinx_sys_rst i_xilinx_sys_rst (
    .slowest_sync_clk(ref_clk),
    .ext_reset_in(pad_reset),
    .aux_reset_in(1'b1),
    .mb_debug_sys_rst(1'b0),
    .dcm_locked(locked_sig), 
    .mb_reset(sys_mb_reset),
    .bus_struct_reset(sys_bus_struct_reset),
    .peripheral_reset(sys_peripheral_reset),
    .interconnect_aresetn(sys_interconnect_aresetn),
    .peripheral_aresetn(sys_peripheral_aresetn)
  );



  // Main AIDA top-level instance
  aida_top i_aida_top (
    .clk_i(ref_clk),
    .rst_ni(~sys_mb_reset),      // Use system reset controller output
    .fetch_enable_i(1'b1),

    // JTAG signals
    .jtag_tck_i(jtag_tck_gated),
    .jtag_trst_ni(~sys_mb_reset),
    .jtag_tms_i(jtag_tms_o),
    .jtag_tdi_i(jtag_tdi_o),
    .jtag_tdo_o(jtag_tdo_i)
  );

endmodule
