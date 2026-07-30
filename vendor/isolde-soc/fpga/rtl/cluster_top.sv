// Copyleft 2024 ISOLDE





module cluster_top
  import ibex_pkg::*;
  // import redmule_pkg::*;
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
    output aida_io_pkg::aida_pads_o_t pads_o
    `ifdef TARGET_RV_DEBUG
    // === JTAG port ===
    ,input jtag_pkg::jtag_req_t soc_jtag_in,
    output jtag_pkg::jtag_rsp_t soc_jtag_out
    `endif
    `ifdef TARGET_VERILATOR
        ,output logic[31:0] sim_exit_code_o,
        output logic sim_exit_valid_o    
    `endif 
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



`ifdef TARGET_SPM
  /********************************************************/
  /**    aida core                                       **/
  /********************************************************/

  isolde_cluster #(
      .BootROMEnable(BootROMEnable)
  ) i_aida (
      .clk_i(clk_i),
      .rst_ni(rst_ni),
      .fetch_enable_i(fetch_enable_i),
      .aida_data_memory(aida_data_memory),
      .aida_stack_memory(aida_stack_memory),
      .aida_instr_memory(aida_instr_memory),

      .pads_o(pads_o)
`ifdef TARGET_RV_DEBUG
      ,.aida_jtag_in(soc_jtag_in),
      .aida_jtag_out(soc_jtag_out)
`endif
`ifdef TARGET_VERILATOR
      ,.sim_exit_code_o,
      .sim_exit_valid_o
`endif

  );
`else
  `error "Unsupported target"
`endif

  /********************************************************/


endmodule  // isolde_cluster
