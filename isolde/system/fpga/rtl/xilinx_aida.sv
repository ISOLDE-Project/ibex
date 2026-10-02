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
    output wire GPIO_LED_3,

    //UART TX
    output wire pad_uart_tx

);

  // --------------------------------------------------------------------------
  // Boot configuration -- keep in sync with
  //   vendor/isolde-soc/fpga/tb/aida_tb.sv
  //
  //   BootROMEnable = 1 : BOOT_ADDR = ROM_BOOT_ADDR (0x0000_0080). The core
  //                       parks in isolde_boot_rom (a 2-instruction self-loop)
  //                       until a debugger loads an image and sets the PC.
  //   BootROMEnable = 0 : BOOT_ADDR = RV_BOOT_ADDR (0x0010_0080). The core runs
  //                       whatever is already in the instruction memory.
  //
  // This is a `parameter` (not a `localparam`) on purpose: it is the elaborated
  // top of the Vivado run, so it can be overridden with
  //   set_property generic {BootROMEnable=0} [current_fileset]
  // --------------------------------------------------------------------------
`ifdef TARGET_RV_DEBUG
  parameter bit BootROMEnable = 1'b1;
`else
  parameter bit BootROMEnable = 1'b0;
`endif

  // JTAG Static connection signals
  jtag_pkg::jtag_req_t jtag_req;
  jtag_pkg::jtag_rsp_t jtag_rsp;

  // AIDA pad outputs
  aida_io_pkg::aida_pads_o_t pads_o;

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
      .soc2pads_i(pads_o),

      //Pads
      .pad_jtag_tms(pad_jtag_tms),
      .pad_jtag_tdi(pad_jtag_tdi),
      .pad_jtag_tdo(pad_jtag_tdo),
      .pad_jtag_tck(jtag_tck_buf),
      .pad_uart_tx (pad_uart_tx)
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
  // --------------------------------------------------------------------------
  // DUT selection.
  // Must use the SAME define as vendor/isolde-soc/fpga/tb/aida_tb.sv, otherwise
  // simulation and FPGA build different SoCs:
  //   REDMULE_CLUSTER defined  -> cluster_top  (requires TARGET_SPM)
  //   REDMULE_CLUSTER undefined-> aida_top     (aida / rv_domain)
  // `make CLUSTER=1` (default) adds `-D REDMULE_CLUSTER` to the bender script.
  // --------------------------------------------------------------------------
`ifdef REDMULE_CLUSTER
  cluster_top #(
      .BootROMEnable(BootROMEnable)
  ) i_cluster_top (
`else
  aida_top #(
      .BootROMEnable(BootROMEnable)
  ) i_aida_top (
`endif
      .clk_i         (ref_clk),
      .rst_ni        (~sys_mb_reset),  // Use system reset controller output
      .fetch_enable_i(fetch_enable),
      // Pads
      .pads_o        (pads_o)
`ifdef TARGET_RV_DEBUG
      // JTAG port
      ,.soc_jtag_in  (jtag_req),
      .soc_jtag_out  (jtag_rsp)
`endif
  );

`ifndef TARGET_RV_DEBUG
  // No debug module in this configuration: keep the TAP outputs defined.
  assign jtag_rsp = '0;
`endif

  // LED is ON when reset is active (logic high)
  assign GPIO_LED_0 = locked_sig;
  assign GPIO_LED_1 = sys_mb_reset;
  assign GPIO_LED_2 = fetch_enable;
  assign GPIO_LED_3 = 1'b1;  // Always ON

endmodule
