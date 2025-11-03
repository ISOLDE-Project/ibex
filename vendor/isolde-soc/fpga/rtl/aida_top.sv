// Copyleft 2024 ISOLDE





module aida_top
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

    parameter rv32m_e   RV32M   = RV32MSingleCycle,
    parameter rv32b_e   RV32B   = RV32BNone,
    parameter regfile_e RegFile = RegFileFPGA,

    parameter int unsigned DmHaltAddr      = 32'h1A11_0800,
    parameter int unsigned DmExceptionAddr = 32'h1A11_0808,
    parameter bit          BootROMEnable   = 1'b1
) (
    input logic clk_i,
    input logic rst_ni,
    input logic fetch_enable_i,
    // === output ports ===
    output aida_io_pkg::aida_pads_o_t pads_o,
    // === JTAG port ===
    input jtag_pkg::jtag_req_t soc_jtag_in,
    output jtag_pkg::jtag_rsp_t soc_jtag_out
       
);







  /********************************************************/
  /**           Interface Definitions                   **/
  /*******************************************************/
  // ===  Memory banks  connections ===
  isolde_tcdm_pkg::req_t mem_req[N_TCDM_BANKS-1:0];
  isolde_tcdm_pkg::rsp_t mem_rsp[N_TCDM_BANKS-1:0];

  // === instruction memory port ===
  isolde_tcdm_if aida_instr_memory ();

  // === Data port ===
  isolde_tcdm_if aida_data_memory ();

  // === stack memory port ===
  isolde_tcdm_if aida_stack_memory ();



  /********************************************************/
  /**     Data memory                                    **/
  /*******************************************************/
  tcdm_mem #(
      .MEMORY_SIZE(2048),
      .MEMORY_PRIMITIVE("ultra")
  ) i_dummy_dmemory (
      .clk_i,
      .rst_ni,
      .tcdm_slave_i(aida_data_memory)
  );

  /********************************************************/
  /**     Instruction memory                             **/
  /*******************************************************/
  tcdm_mem #(
      .MEMORY_SIZE(2048),
      //.DELAY_CYCLES(IMEM_LATENCY),
      .MEMORY_PRIMITIVE("ultra")
  ) i_dummy_imemory (
      .clk_i,
      .rst_ni,
      .tcdm_slave_i(aida_instr_memory)
  );


  /********************************************************/
  /**     Stack memory                                   **/
  /*******************************************************/
  tcdm_mem #() i_dummy_stack_memory (
      .clk_i,
      .rst_ni,
      .tcdm_slave_i(aida_stack_memory)
  );


  /********************************************************/
  /**     TCDM                                           **/
  /*******************************************************/

  // === Memory banks ===
  generate
    for (genvar i = 0; i < N_TCDM_BANKS; i++) begin : gen_mem
      // Instantiate memory bank
      tcdm_mem_wrapper #() i_bank (
          .clk_i(clk_i),
          .rst_ni(rst_ni),
          .req_req(mem_req[i].req),
          .req_we(mem_req[i].we),
          .req_be(mem_req[i].be),
          .req_addr(mem_req[i].addr),
          .req_data(mem_req[i].data),
          .gnt(mem_rsp[i].gnt),
          .valid(mem_rsp[i].valid),
          .err(mem_rsp[i].err),
          .rsp_data(mem_rsp[i].data)
      );
    end
  endgenerate


  /********************************************************/
  /**    aida core                                      **/
  /*******************************************************/

  aida_lca #(
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
  ) i_aida_lca (
      .clk_i(clk_i),
      .rst_ni(rst_ni),
      .fetch_enable_i(fetch_enable_i),
      .aida_data_memory(aida_data_memory),
      .aida_stack_memory(aida_stack_memory),
      .aida_instr_memory(aida_instr_memory),
      
      .pads_o(pads_o),

      .spm_req_o(mem_req),
      .spm_rsp_i(mem_rsp),
      .aida_jtag_in(soc_jtag_in),
      .aida_jtag_out(soc_jtag_out)

  );


  /********************************************************/


endmodule  // aida_top
