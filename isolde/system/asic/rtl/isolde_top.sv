/**
 * Top level module of the ibex RISC-V core
 */
module isolde_top
  import ibex_pkg::*;
#(
    parameter bit PMPEnable = 1'b0,
    parameter int unsigned PMPGranularity = 0,
    parameter int unsigned PMPNumRegions = 4,
    parameter int unsigned MHPMCounterNum = 0,
    parameter int unsigned MHPMCounterWidth = 40,
    parameter bit RV32E = 1'b0,
    parameter rv32m_e RV32M = RV32MFast,
    parameter rv32b_e RV32B = RV32BNone,
    parameter regfile_e RegFile = RegFileFF,
    parameter bit BranchTargetALU = 1'b0,
    parameter bit WritebackStage = 1'b0,
    parameter bit ICache = 1'b0,
    parameter bit ICacheECC = 1'b0,
    parameter bit BranchPredictor = 1'b0,
    parameter bit DbgTriggerEn = 1'b0,
    parameter int unsigned DbgHwBreakNum = 1,
    parameter bit SecureIbex = 1'b0,
    parameter bit ICacheScramble = 1'b0,
    parameter int unsigned ICacheScrNumPrinceRoundsHalf = 2,
    parameter lfsr_seed_t RndCnstLfsrSeed = RndCnstLfsrSeedDefault,
    parameter lfsr_perm_t RndCnstLfsrPerm = RndCnstLfsrPermDefault,
    parameter int unsigned DmHaltAddr = 32'h1A110800,
    parameter int unsigned DmExceptionAddr = 32'h1A110808,
    // Default seed and nonce for scrambling
    parameter logic [SCRAMBLE_KEY_W-1:0] RndCnstIbexKey = RndCnstIbexKeyDefault,
    parameter logic [SCRAMBLE_NONCE_W-1:0] RndCnstIbexNonce = RndCnstIbexNonceDefault
) (
    // Clock and Reset
    input logic clk_i,
    input logic rst_ni,

    // Instruction memory interface
    output logic        instr_req_o,
    input  logic        instr_gnt_i,
    input  logic        instr_rvalid_i,
    output logic [31:0] instr_addr_o,
    input  logic [31:0] instr_rdata_i,
    input  logic [ 6:0] instr_rdata_intg_i,
    input  logic        instr_err_i,

    // Data memory interface
    output logic        data_req_o,
    input  logic        data_gnt_i,
    input  logic        data_rvalid_i,
    output logic        data_we_o,
    output logic [ 3:0] data_be_o,
    output logic [31:0] data_addr_o,
    output logic [31:0] data_wdata_o,
    output logic [ 6:0] data_wdata_intg_o,
    input  logic [31:0] data_rdata_i,
    input  logic [ 6:0] data_rdata_intg_i,
    input  logic        data_err_i,

    // Interrupt inputs
    input logic irq_software_i,

    // Debug Interface
    input logic debug_req_i,

    // CPU Control Signals
    input  ibex_mubi_t fetch_enable_i,
    output logic       alert_minor_o,
    output logic       alert_major_internal_o,
    output logic       alert_major_bus_o,
    output logic       core_sleep_o

);

  isolde_cv_x_if #(
      .X_NUM_RS   (isolde_cv_x_if_pkg::X_NUM_RS),
      .X_ID_WIDTH (isolde_cv_x_if_pkg::X_ID_WIDTH),
      .X_MEM_WIDTH(isolde_cv_x_if_pkg::X_MEM_WIDTH),
      .X_RFR_WIDTH(isolde_cv_x_if_pkg::X_RFR_WIDTH),
      .X_RFW_WIDTH(isolde_cv_x_if_pkg::X_RFW_WIDTH),
      .X_MISA     (isolde_cv_x_if_pkg::X_MISA),
      .X_ECS_XS   (isolde_cv_x_if_pkg::X_ECS_XS)
  ) itf_core_xif ();

  ibex_top #(

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
      .DmHaltAddr      (DmHaltAddr),
      .DmExceptionAddr (DmExceptionAddr)
  ) i_ibex_top (
      .clk_i (clk_i),
      .rst_ni(rst_ni),

      .test_en_i  (1'b0),
      .scan_rst_ni(1'b1),
      .ram_cfg_i  (prim_ram_1p_pkg::RAM_1P_CFG_DEFAULT),

      .hart_id_i  (32'b0),
      // First instruction executed is at 0x0 + 0x80
      .boot_addr_i(RV_BOOT_ADDR),
      // === Instruction memory interface
      .instr_req_o,
      .instr_gnt_i,
      .instr_rvalid_i,
      .instr_addr_o,
      .instr_rdata_i,
      .instr_rdata_intg_i,
      .instr_err_i,
      // === Data memory interface
      .data_req_o,
      .data_gnt_i,
      .data_rvalid_i,
      .data_addr_o,
      .data_be_o,
      .data_we_o,
      .data_wdata_o,
      .data_wdata_intg_o,
      .data_rdata_i,
      .data_rdata_intg_i,
      .data_err_i,

      .irq_software_i,
      .irq_timer_i   (1'b0),
      .irq_external_i(1'b0),
      .irq_fast_i    (1'b0),
      .irq_nm_i      (1'b0),

      .scramble_key_valid_i('0),
      .scramble_key_i      ('0),
      .scramble_nonce_i    ('0),
      .scramble_req_o      (),

      .debug_req_i,
      .crash_dump_o       (),
      .double_fault_seen_o(),

      .fetch_enable_i,
      .alert_minor_o         (),
      .alert_major_internal_o(),
      .alert_major_bus_o     (),
      .core_sleep_o,
      // eXtension interface
      .xif_compressed_if     (itf_core_xif.cpu_compressed),
      .xif_issue_if          (itf_core_xif.cpu_issue),
      .xif_commit_if         (itf_core_xif.cpu_commit),
      .xif_mem_if            (itf_core_xif.cpu_mem),
      .xif_mem_result_if     (itf_core_xif.cpu_mem_result),
      .xif_result_if         (itf_core_xif.cpu_result)
  );
endmodule
