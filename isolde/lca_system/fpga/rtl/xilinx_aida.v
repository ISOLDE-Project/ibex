// Copyleft ISOLDE 2025

module xilinx_aida (
    input  wire CLK_IN1_D_0_clk_p,
    input  wire CLK_IN1_D_0_clk_n,
    input  wire pad_reset,

    // JTAG
    inout  wire pad_jtag_tck,
    inout  wire pad_jtag_tdi,
    inout  wire pad_jtag_tdo,
    inout  wire pad_jtag_tms
);

  // Internal clock and reset signals
  wire ref_clk;
  wire sys_mb_reset;
  wire locked_sig;

  wire [0:0] sys_bus_struct_reset;
  wire [0:0] sys_peripheral_reset;
  wire [0:0] sys_interconnect_aresetn;
  wire [0:0] sys_peripheral_aresetn;

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
    .jtag_tck_i(pad_jtag_tck),
    .jtag_trst_ni(1'b1),
    .jtag_tms_i(pad_jtag_tms),
    .jtag_tdi_i(pad_jtag_tdi),
    .jtag_tdo_o(pad_jtag_tdo)
  );

endmodule
