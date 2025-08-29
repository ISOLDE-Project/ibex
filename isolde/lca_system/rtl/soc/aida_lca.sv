module aida_lca
  import ibex_pkg::*;
  import redmule_pkg::*;
  import isolde_tcdm_pkg::*;
  import aida_lca_package::*;
#(
    parameter bit          PMPEnable        = 1'b0,
    parameter int unsigned PMPGranularity   = 0,
    parameter int unsigned PMPNumRegions    = 4,
    parameter int unsigned MHPMCounterNum   = 0,
    parameter int unsigned MHPMCounterWidth = 40,
    parameter bit          RV32E            = 1'b0,
    parameter rv32m_e      RV32M            = RV32MFast,
    parameter rv32b_e      RV32B            = RV32BNone,
    parameter regfile_e    RegFile          = RegFileFF,
    parameter bit          BranchTargetALU  = 1'b0,
    parameter bit          WritebackStage   = 1'b0,
    parameter bit          ICache           = 1'b0,
    parameter bit          ICacheECC        = 1'b0,
    parameter bit          BranchPredictor  = 1'b0,
    parameter bit          DbgTriggerEn     = 1'b0,
    parameter int unsigned DbgHwBreakNum    = 1,
    parameter bit          SecureIbex       = 1'b0,
    parameter bit          ICacheScramble   = 1'b0,
    parameter lfsr_seed_t  RndCnstLfsrSeed  = RndCnstLfsrSeedDefault,
    parameter lfsr_perm_t  RndCnstLfsrPerm  = RndCnstLfsrPermDefault,
    parameter int unsigned DmHaltAddr       = 32'h1A110800,
    parameter int unsigned DmExceptionAddr  = 32'h1A110808
) (
    input  logic                 clk_i,
    input  logic                 rst_ni,
    input  logic                 fetch_enable_i,
           isolde_tcdm_if.master aida_data_memory,
    //   isolde_tcdm_if.master aida_stack_memory,
           isolde_tcdm_if.master aida_instr_memory,
        //   isolde_tcdm_if.master aida_mmio,
    // === debugger module ports ===
           isolde_tcdm_if.slave  tcdm_dm_periph,
           isolde_tcdm_if.master tcdm_dm_sba,
    input  logic                 evt_i,
    input  jtag_pkg::jtag_req_t  aida_jtag_in,
    output jtag_pkg::jtag_rsp_t  aida_jtag_out

);

  logic [rv_dm_pkg::NrHarts-1:0] debug_req;

  logic                          core_sleep;

  /********************************************************/
  /**     RV Debug Module                                **/
  /*******************************************************/
  rv_dm #() i_rv_dm (
      .clk_i,
      .rst_ni,
      /// Debug Module Interface (DMI) slave port 
      .s_periph(tcdm_dm_periph),
      //.s_dmi(tcdm_inst_dm),
      /// System Bus master port
      .m_sba(tcdm_dm_sba),
      /// JTAG
      .jtag_in(aida_jtag_in),
      .jtag_out(aida_jtag_out),
      .debug_req_o(debug_req)
  );


  /********************************************************/
  /**     CV-X-IF                                        **/
  /*******************************************************/

  isolde_cv_x_if #(
      .X_NUM_RS   (isolde_cv_x_if_pkg::X_NUM_RS),
      .X_ID_WIDTH (isolde_cv_x_if_pkg::X_ID_WIDTH),
      .X_MEM_WIDTH(isolde_cv_x_if_pkg::X_MEM_WIDTH),
      .X_RFR_WIDTH(isolde_cv_x_if_pkg::X_RFR_WIDTH),
      .X_RFW_WIDTH(isolde_cv_x_if_pkg::X_RFW_WIDTH),
      .X_MISA     (isolde_cv_x_if_pkg::X_MISA),
      .X_ECS_XS   (isolde_cv_x_if_pkg::X_ECS_XS)
  ) itf_core_xif ();

  xif_monitor_cpu_issue xif_monitor_cpu_issue_i (
      clk_i,
      itf_core_xif
  );

  /********************************************************/
  /**     IBEX core                                     **/
  /*******************************************************/

  ibex_top_tracing #(
      .SecureIbex      (SecureIbex),
      .ICacheScramble  (ICacheScramble),
      .PMPEnable       (PMPEnable),
      .PMPGranularity  (PMPGranularity),
      .PMPNumRegions   (PMPNumRegions),
      .MHPMCounterNum  (MHPMCounterNum),
      .MHPMCounterWidth(MHPMCounterWidth),
      .RV32E           (RV32E),
      .RV32M           (RV32M),
      .RV32B           (RV32B),
      .RegFile         (RegFile),
      .BranchTargetALU (BranchTargetALU),
      .ICache          (ICache),
      .ICacheECC       (ICacheECC),
      .WritebackStage  (WritebackStage),
      .BranchPredictor (BranchPredictor),
      .DbgTriggerEn    (DbgTriggerEn),
      .DmHaltAddr      (32'h1A11_0800),     //TODO make a param here
      .DmExceptionAddr (32'h1A11_0808)      //TODO make a param here
  ) i_ibex_tracing (
      .clk_i (clk_i),
      .rst_ni(rst_ni),

      .test_en_i  (1'b0),
      .scan_rst_ni(1'b1),
      .ram_cfg_i  (prim_ram_1p_pkg::RAM_1P_CFG_DEFAULT),

      .hart_id_i        (32'b0),
      // First instruction executed is at 0x0 + 0x80
      .boot_addr_i      (BOOT_ADDR),
      // Instruction memory interface
      .instr_req_o      (aida_instr_memory.req.req),
      .instr_gnt_i      (aida_instr_memory.rsp.gnt),
      .instr_rvalid_i   (aida_instr_memory.rsp.valid),
      .instr_addr_o     (aida_instr_memory.req.addr),
      .instr_rdata_i    (aida_instr_memory.rsp.data),
      //.instr_rdata_intg_i     (instr_rdata_intg),
      //.instr_err_i            (instr_err),
      //     // Data memory interface
      .data_req_o       (aida_data_memory.req.req),
      .data_gnt_i       (aida_data_memory.rsp.gnt),
      .data_rvalid_i    (aida_data_memory.rsp.valid),
      .data_addr_o      (aida_data_memory.req.addr),
      .data_be_o        (aida_data_memory.req.be),
      .data_we_o        (aida_data_memory.req.we),
      .data_wdata_o     (aida_data_memory.req.data),
      .data_wdata_intg_o(),
      .data_rdata_i     (aida_data_memory.rsp.data),
      .data_rdata_intg_i(),
      .data_err_i       (),

      .irq_software_i(evt_i),
      .irq_timer_i   (1'b0),
      .irq_external_i(1'b0),
      .irq_fast_i    (1'b0),
      .irq_nm_i      (1'b0),

      .scramble_key_valid_i('0),
      .scramble_key_i      ('0),
      .scramble_nonce_i    ('0),
      .scramble_req_o      (),

      .debug_req_i        (debug_req[0]),
      .crash_dump_o       (),
      .double_fault_seen_o(),

      .fetch_enable_i        (fetch_enable_i),
      .alert_minor_o         (),
      .alert_major_internal_o(),
      .alert_major_bus_o     (),
      .core_sleep_o          (core_sleep),
      // eXtension interface
      .xif_compressed_if     (itf_core_xif.cpu_compressed),
      .xif_issue_if          (itf_core_xif.cpu_issue),
      .xif_commit_if         (itf_core_xif.cpu_commit),
      .xif_mem_if            (itf_core_xif.cpu_mem),
      .xif_mem_result_if     (itf_core_xif.cpu_mem_result),
      .xif_result_if         (itf_core_xif.cpu_result)
  );

endmodule
