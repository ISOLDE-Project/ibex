// Copyleft ISOLDE 2025

module cluster_tb (
    input logic clk_i,
    input logic rst_ni
    // input logic fetch_enable_i

);

  // import redmule_pkg::*;
  import isolde_tcdm_pkg::*;
  import aida_lca_package::*;
  //ibex parameters
  parameter bit SecureIbex = 1'b0;
  parameter bit ICacheScramble = 1'b0;
  parameter bit PMPEnable = 1'b0;
  parameter int unsigned PMPGranularity = 0;
  parameter int unsigned PMPNumRegions = 4;
  parameter int unsigned MHPMCounterNum = 0;
  parameter int unsigned MHPMCounterWidth = 40;
  parameter bit RV32E = 1'b0;
  parameter ibex_pkg::rv32m_e RV32M = `RV32M;
  parameter ibex_pkg::rv32b_e RV32B = `RV32B;
  parameter ibex_pkg::regfile_e RegFile = `RegFile;
  parameter bit BranchTargetALU = 1'b0;
  parameter bit WritebackStage = 1'b0;
  parameter bit ICache = 1'b0;
  parameter bit DbgTriggerEn = 1'b0;
  parameter bit ICacheECC = 1'b0;
  parameter bit BranchPredictor = 1'b0;
  parameter int unsigned IMEM_LATENCY = 0;
`ifdef TARGET_RV_DEBUG
  parameter bit BootROMEnable = 1'b1;  // enable booting from ROM
`else
  parameter bit BootROMEnable = 1'b0;  // enable booting from instr memory
`endif

`ifndef TARGET_RV_DEBUG
  logic [31:0] sim_exit_code;
  logic        sim_exit_valid;
`endif
  string stim_instr, stim_data;

  /********************************************************/
  /**  JTAG Static connection signals                   **/
  /*******************************************************/
  `ifdef TARGET_RV_DEBUG
  logic [31:0] sim_jtag_exit;
  // === JTAG simulation parameters
  localparam int unsigned OPENOCD_PORT = 9999;
  jtag_pkg::jtag_req_t jtag_req;
  jtag_pkg::jtag_rsp_t jtag_rsp;
  `endif
  // === IO pads outputs
  aida_io_pkg::aida_pads_o_t pads_o;

  // Internal clock and reset signals
  wire ref_clk;
  wire sys_mb_reset;


  assign ref_clk = clk_i;
  assign sys_mb_reset = rst_ni;



  /********************************************************/
  /**           VERILATOR BUG                            **/
  /*******************************************************/

  //hwpe_ctrl_intf_periph #(.ID_WIDTH(ID)) periph (.clk(clk_i));
  /**
  * Bug in Verilator?! 
  * Verilator 5.036 2025-04-27 rev v5.036
  %Error-UNSUPPORTED: /home/dan/ibex/isolde/lca_system/.bender/git/checkouts/hwpe-stream-8301a9eab8e707b9/rtl/tcdm/hwpe_stream_tcdm_fifo_store.sv:82:32: Unsupported: Interfaced port on top level module
   82 |   hwpe_stream_intf_tcdm.slave  tcdm_slave,
      |                                ^~~~~~~~~~
                    ... For error description see https://verilator.org/warn/UNSUPPORTED?v=5.036
  %Error: /home/dan/ibex/isolde/lca_system/.bender/git/checkouts/hwpe-stream-8301a9eab8e707b9/rtl/tcdm/hwpe_stream_tcdm_fifo_store.sv:82:3: Parent instance's interface is not found: 'hwpe_stream_intf_tcdm'
* FIX: declare a dummy hwpe_stream_intf_tcdm variable
*/
  hwpe_stream_intf_tcdm dummy_intf (
      .clk(clk_i)
  );  // dummy interface for hwpe_stream_tcdm_fifo_store

  /********************************************************/
  /**          Simulation end                            **/
  /*******************************************************/

`ifndef TARGET_RV_DEBUG
  always @(posedge clk_i) begin
    if (sim_exit_valid) begin
      endSimulation(sim_exit_code);
    end
  end
`endif

`ifdef TARGET_RV_DEBUG
  /********************************************************/
  /**     JTAG simulation                                **/
  /*******************************************************/
  SimJTAG #(
      .TICK_DELAY(1),
      .PORT(OPENOCD_PORT)
  ) i_sim_jtag (
      .clock          (clk_i),
      .reset          (~rst_ni),
      .enable         (1'b1),
      .init_done      (rst_ni),
      .jtag_TCK       (jtag_req.tck),
      .jtag_TMS       (jtag_req.tms),
      .jtag_TDI       (jtag_req.tdi),
      .jtag_TRSTn     (jtag_req.trst_n),
      .jtag_TDO_data  (jtag_rsp.tdo),
      .jtag_TDO_driven(jtag_rsp.tdo_oe),
      .exit           (sim_jtag_exit)
  );

  always @(posedge clk_i) begin : jtag_exit_handler
    if (sim_jtag_exit) endSimulation(32'h0);
  end
`endif

  wire fetch_enable;
  ibex_rst i_ibex_rst (
      .clk_i(ref_clk),
      .rst_ni(sys_mb_reset),
      .fetch_enable_o(fetch_enable)
  );


  
  cluster_top #(
      .BootROMEnable(BootROMEnable)
  ) i_cluster (
      .clk_i         (ref_clk),
      .rst_ni        (sys_mb_reset),  // Use system reset controller output
      .fetch_enable_i(fetch_enable),

      .pads_o,
    `ifdef TARGET_RV_DEBUG
      // JTAG port
      .soc_jtag_in(jtag_req),
      .soc_jtag_out(jtag_rsp),
    `endif
      .sim_exit_code_o(sim_exit_code),
      .sim_exit_valid_o(sim_exit_valid)
  );



  // Declare the task with an input parameter for errors
  task endSimulation(input int errors);

    if (errors != 0) begin
      $display("[FPGA SIM] @ t=%0t - Fail!", $time);
      $display("[FPGA SIM] @ t=%0t - errors=%08x", $time, errors);
    end else begin
      $display("[FPGA SIM] @ t=%0t - Success!", $time);
      $display("[FPGA SIM] @ t=%0t - errors=%08x", $time, errors);
    end
    $finish;
  endtask

  initial begin


    // Load instruction and data memory
    if (!$value$plusargs("STIM_INSTR=%s", stim_instr)) begin
      $display("No STIM_INSTR specified");
      $finish;
    end else begin
      $display("[FPGA SIM] @ t=%0t: loading %0s into imemory", $time, stim_instr);
      $readmemh(stim_instr, cluster_tb.i_cluster.i_imemory.u_tcdm_mem.memory);
    end

    if (!$value$plusargs("STIM_DATA=%s", stim_data)) begin
      $display("No STIM_DATA specified");
      $finish;
    end else begin
      $display("[FPGA SIM] @ t=%0t: loading %0s into dmemory", $time, stim_data);
      $readmemh(stim_data, cluster_tb.i_cluster.i_dmemory.u_tcdm_mem.memory);
    end


  end

endmodule
