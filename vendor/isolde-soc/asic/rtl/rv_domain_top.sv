// Copyleft 2024 ISOLDE





module rv_domain_top
  import ibex_pkg::*;
  import redmule_pkg::*;
  import isolde_tcdm_pkg::*;
  import aida_lca_package::*;
#(
    //ibex parameters
    parameter bit RV32E           = 1'b0,
    parameter bit ICacheScramble  = 1'b0,
    parameter bit ICache          = 1'b0,
    parameter bit ICacheECC       = 1'b0,
    parameter bit BranchTargetALU = 1'b0,
    parameter bit WritebackStage  = 1'b0,
    parameter bit SecureIbex      = 1'b0,
    parameter bit BranchPredictor = 1'b0,
    parameter bit DbgTriggerEn    = 1'b0,

    parameter bit          PMPEnable        = 1'b0,
    parameter int unsigned PMPGranularity   = 0,
    parameter int unsigned PMPNumRegions    = 4,
    parameter int unsigned MHPMCounterNum   = 0,
    parameter int unsigned MHPMCounterWidth = 40,

    parameter rv32m_e   RV32M   = RV32MFast,
    parameter rv32b_e   RV32B   = RV32BNone,
    parameter regfile_e RegFile = RegFileFF,

    parameter int unsigned DmHaltAddr      = 32'h1A11_0800,
    parameter int unsigned DmExceptionAddr = 32'h1A11_0808,
    parameter bit          BootROMEnable   = 1'b1
) (
    input logic clk_i,
    input logic rst_ni,
    input logic fetch_enable_i,
    // === instruction memory port ===
    isolde_tcdm_pkg::req_t instr_req,
    isolde_tcdm_pkg::rsp_t instr_rsp,
    // === Data memory port ===
    isolde_tcdm_pkg::req_t data_req,
    isolde_tcdm_pkg::rsp_t data_rsp,
    // === Stack memory port ===
    isolde_tcdm_pkg::req_t stack_req,
    isolde_tcdm_pkg::rsp_t stack_rsp,
    // AIDA pad outputs
    aida_io_pkg::aida_pads_o_t pads_o,
    // === JTAG port ===
    input jtag_pkg::jtag_req_t soc_jtag_in,
    output jtag_pkg::jtag_rsp_t soc_jtag_out

);







  /********************************************************/
  /**           Interface Definitions                   **/
  /*******************************************************/

  // === instruction memory port ===
  isolde_tcdm_if aida_instr_memory ();

  // === Data port ===
  isolde_tcdm_if aida_data_memory ();

  // === stack memory port ===
  isolde_tcdm_if aida_stack_memory ();


  assign instr_req = aida_instr_memory.req;
  assign aida_instr_memory.rsp = instr_rsp;

  assign data_req = aida_data_memory.req;
  assign aida_data_memory.rsp = data_rsp;

  assign stack_req = aida_stack_memory.req;
  assign aida_stack_memory.rsp = stack_rsp;



  /********************************************************/
  /**    rv_domain core                                      **/
  /*******************************************************/

  rv_domain #(
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
      .DmExceptionAddr (DmExceptionAddr),
      .BootROMEnable   (BootROMEnable)
  ) i_rv_domain (
      .clk_i(clk_i),
      .rst_ni(rst_ni),
      .fetch_enable_i(fetch_enable_i),
      .aida_data_memory(aida_data_memory),
      .aida_stack_memory(aida_stack_memory),
      .aida_instr_memory(aida_instr_memory),

      .pads_o(pads_o),

      .aida_jtag_in (soc_jtag_in),
      .aida_jtag_out(soc_jtag_out)

  );


  /********************************************************/


endmodule  // rv_domain_top
