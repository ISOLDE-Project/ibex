// Copyleft 2024 ISOLDE





module aida_top
  import ibex_pkg::*;
  import redmule_pkg::*;
  import isolde_tcdm_pkg::*;
  import aida_lca_package::*;
#(
    //ibex parameter(s)
    parameter bit BootROMEnable = 1'b1
) (
    input logic clk_i,
    input logic rst_ni,
    input logic fetch_enable_i,
    // === output ports ===
    output aida_io_pkg::aida_pads_o_t pads_o,
    // === JTAG port ===
    input jtag_pkg::jtag_req_t soc_jtag_in,
    output jtag_pkg::jtag_rsp_t soc_jtag_out
    `ifdef TARGET_VERILATOR
        ,output logic[31:0] sim_exit_code_o,
        output logic sim_exit_valid_o    
    `endif 
);







  /********************************************************/
  /**           Interface Definitions                   **/
  /*******************************************************/
`ifdef TARGET_SPM
  // ===  Memory banks  connections ===
  isolde_tcdm_pkg::req_t mem_req[N_TCDM_BANKS-1:0];
  isolde_tcdm_pkg::rsp_t mem_rsp[N_TCDM_BANKS-1:0];
`endif
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
      .MEMORY_SIZE(DMEM_SIZE_I32),
      .MEMORY_PRIMITIVE("ultra")
  ) i_dmemory (
      .clk_i,
      .rst_ni,
      .tcdm_slave_i(aida_data_memory)
  );

  /********************************************************/
  /**     Instruction memory                             **/
  /*******************************************************/
  tcdm_mem #(
      .MEMORY_SIZE(IMEM_SIZE_I32),
      .MEMORY_PRIMITIVE("ultra")
  ) i_imemory (
      .clk_i,
      .rst_ni,
      .tcdm_slave_i(aida_instr_memory)
  );


  /********************************************************/
  /**     Stack memory                                   **/
  /*******************************************************/
  tcdm_mem #(
      .MEMORY_SIZE(SMEM_SIZE_I32),
      .MEMORY_PRIMITIVE("ultra")
  ) i_stack_memory (
      .clk_i,
      .rst_ni,
      .tcdm_slave_i(aida_stack_memory)
  );


  /********************************************************/
  /**     TCDM                                           **/
  /*******************************************************/
`ifdef TARGET_SPM
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
          //.err(mem_rsp[i].err),
          .rsp_data(mem_rsp[i].data)
      );
    end
  endgenerate

`endif
`ifdef TARGET_SPM
  /********************************************************/
  /**    aida core                                       **/
  /********************************************************/

  aida #(
      .BootROMEnable(BootROMEnable)
  ) i_aida (
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
`ifdef TARGET_VERILATOR,
      .sim_exit_code_o,
      .sim_exit_valid_o
`endif

  );
`else
  /********************************************************/
  /**    risc-v domain                                   **/
  /********************************************************/

  rv_domain #(
      .BootROMEnable(BootROMEnable)
  ) i_rv_domain (
      .clk_i(clk_i),
      .rst_ni(rst_ni),
      .fetch_enable_i(fetch_enable_i),
      .aida_data_memory(aida_data_memory),
      .aida_stack_memory(aida_stack_memory),
      .aida_instr_memory(aida_instr_memory),

      .pads_o(pads_o),
      .aida_jtag_in(soc_jtag_in),
      .aida_jtag_out(soc_jtag_out)
`ifdef TARGET_VERILATOR,
      .sim_exit_code_o,
      .sim_exit_valid_o
`endif
  );
`endif

  /********************************************************/


endmodule  // aida_top
