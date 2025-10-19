// Copyleft ISOLDE 2025

module xilinx_aida (
    input wire CLK_IN1_D_0_clk_p,
    input wire CLK_IN1_D_0_clk_n,
    input wire pad_reset,

    // JTAG
    input wire pad_jtag_tms,
    input wire pad_jtag_tdi,
    inout wire pad_jtag_tdo,
    input wire pad_jtag_tck,

    //user LED
    output wire GPIO_LED_0,
    output wire GPIO_LED_1,
    output wire GPIO_LED_2,
    output wire GPIO_LED_3

);


  // JTAG Static connection signals 
  jtag_pkg::jtag_req_t jtag_req;
  jtag_pkg::jtag_rsp_t jtag_rsp;

  // Internal clock and reset signals
  wire ref_clk;
  wire sys_mb_reset;
  wire locked_sig;

  wire [0:0] sys_bus_struct_reset;
  wire [0:0] sys_peripheral_reset;
  wire [0:0] sys_interconnect_aresetn;
  wire [0:0] sys_peripheral_aresetn;

  // ERROR: [DRC PLHDIO-3] HDIO DRC Checks
  wire jtag_tck_buf;
  BUFGCE i_bufgce_pad_jtag_tck (
      .I (pad_jtag_tck),
      .CE(1'b1),
      .O (jtag_tck_buf)
  );

  //
  aida_padframe i_aida_padframe (
      .pad2soc_jtag_o(jtag_req),
      .soc2pad_jtag_i(jtag_rsp),
      .internal_jtag_trstn(1'b1),
      //
      .pad_jtag_tms(pad_jtag_tms),
      .pad_jtag_tdi(pad_jtag_tdi),
      .pad_jtag_tdo(pad_jtag_tdo),
      .pad_jtag_tck(jtag_tck_buf)
  );

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
      .aux_reset_in(1'b0),
      .mb_debug_sys_rst(1'b0),
      .dcm_locked(locked_sig),
      .mb_reset(sys_mb_reset),
      .bus_struct_reset(sys_bus_struct_reset),
      .peripheral_reset(sys_peripheral_reset),
      .interconnect_aresetn(sys_interconnect_aresetn),
      .peripheral_aresetn(sys_peripheral_aresetn)
  );


  wire fetch_enable;
  ibex_rst i_ibex_rst (
      .clk_i(ref_clk),
      .rst_ni(~sys_mb_reset),
      .fetch_enable_o(fetch_enable)
  );

  // Main AIDA top-level instance
  aida_top i_aida_top (
      .clk_i         (ref_clk),
      .rst_ni        (~sys_mb_reset),  // Use system reset controller output
      .fetch_enable_i(fetch_enable),

      // JTAG port
      .soc_jtag_in (jtag_req),
      .soc_jtag_out(jtag_rsp)
  );

  // LED is ON when reset is active (logic high)
  assign GPIO_LED_0 = locked_sig;
  assign GPIO_LED_1 = sys_mb_reset;
  assign GPIO_LED_2 = fetch_enable;
  assign GPIO_LED_3 = 1'b1; // Always ON

endmodule
