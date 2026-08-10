module isolde_cluster
  import ibex_pkg::*;
  //import redmule_pkg::*;
  import isolde_tcdm_pkg::*;
  import aida_package::*;
#(
    parameter bit          PMPEnable        = 1'b0,
    parameter int unsigned PMPGranularity   = 0,
    parameter int unsigned PMPNumRegions    = 4,
    parameter int unsigned MHPMCounterNum   = 0,
    parameter int unsigned MHPMCounterWidth = 40,
    parameter bit          RV32E            = 1'b0,
    parameter rv32m_e      RV32M            = RV32MSingleCycle,
    parameter rv32b_e      RV32B            = RV32BNone,
    parameter regfile_e    RegFile          = RegFileFF,
    parameter bit          BranchTargetALU  = 1'b0,
    parameter bit          WritebackStage   = 1'b0,
    parameter bit          ICache           = 1'b1,
    parameter bit          ICacheECC        = 1'b0,
    parameter bit          BranchPredictor  = 1'b0,
    parameter bit          DbgTriggerEn     = 1'b0,
    parameter bit          SecureIbex       = 1'b0,
    parameter bit          ICacheScramble   = 1'b0,
    parameter int unsigned DmHaltAddr       = 32'h1A11_0800,
    parameter int unsigned DmExceptionAddr  = 32'h1A11_0808,
    parameter bit          BootROMEnable    = 1'b1
) (
    input  logic                  clk_i,
    input  logic                  rst_ni,
    input  logic                  fetch_enable_i,
           isolde_tcdm_if.master  aida_data_memory,
           isolde_tcdm_if.master  aida_stack_memory,
           isolde_tcdm_if.master  aida_instr_memory,
    //
    output aida_io_pkg::aida_pads_o_t pads_o
        

`ifdef TARGET_RV_DEBUG
    // === JTAG port ===
    ,input  jtag_pkg::jtag_req_t   aida_jtag_in,
    output jtag_pkg::jtag_rsp_t   aida_jtag_out
`endif    
`ifdef TARGET_VERILATOR
    ,output logic[31:0] sim_exit_code_o,
    output logic sim_exit_valid_o    
`endif    

);

  localparam int unsigned N_REDMULE_TILES  = isolde_hwe_cluster_pkg::N_HWE_TILES;

  logic [rv_dm_pkg::NrHarts-1:0]      debug_req;
  logic                               core_sleep;
  logic [                NC-1:0][1:0] tile_evt[N_REDMULE_TILES-1:0];
  logic [N_REDMULE_TILES-1:0] tile_busy;
  logic [                N_REDMULE_TILES-1:0] core_evt;

  isolde_hwe_cluster_pkg::isolde_tile_csr_t  core_evt_mask;
  isolde_hwe_cluster_pkg::isolde_tile_csr_t  core_evt_cpu;

  assign core_evt_cpu = {1'b0,core_evt} & core_evt_mask;

   logic [31:0] BOOT_ADDR;

   assign BOOT_ADDR =  BootROMEnable? ROM_BOOT_ADDR : RV_BOOT_ADDR;


  /********************************************************/
  /**          Router configurations                     **/
  /*******************************************************/

  // DATA
  typedef enum {
`ifdef TARGET_REDMULE_HWPE
    PERIPH_IDX,
`endif
    DATA_IDX,
    STACK_IDX,
    MMIO_IDX,
    SPM_IDX,
`ifdef TARGET_RV_DEBUG
    DEBUG_IDX,
`endif
    LAST_IDX
  } data_map_idx_t;

  localparam int unsigned NoRules = LAST_IDX;
  // 
  localparam addr_range_t addr_map[NoRules] = '{
  `ifdef TARGET_REDMULE_HWPE  
      '{start_addr: PERIPH_ADDR, end_addr: IMEM_ADDR},
   `endif   
      '{start_addr: DMEM_ADDR, end_addr: DMEM_ADDR + DMEM_SIZE},
      '{start_addr: SMEM_ADDR, end_addr: SMEM_ADDR + SMEM_SIZE},           
      '{start_addr: MMIO_ADDR, end_addr: MMIO_ADDR_END},
      '{start_addr: SPM_NARROW_ADDR, end_addr: SPM_NARROW_ADDR + N_REDMULE_TILES*SPM_NARROW_SIZE}
`ifdef TARGET_RV_DEBUG
      , '{start_addr: DEBUG_ADDR, end_addr: DEBUG_ADDR + DEBUG_SIZE}
`endif
  };



`ifdef TARGET_RV_DEBUG
  // DEBUG MODULE PERIPHERAL, instructions memory map
  typedef enum {
    BOOT_MEM_IDX,
    INSTR_MEM_IDX,
    INSTR_DEBUG_IDX,
    INSTR_LAST_IDX
  } instr_map_idx_t;

  
  // 
  localparam addr_range_t instr_map[INSTR_LAST_IDX] = '{
      '{start_addr: ROM_BOOT_ADDR, end_addr: ROM_BOOT_ADDR + ROM_BOOT_SIZE},
      '{start_addr: IMEM_ADDR, end_addr: IMEM_ADDR + IMEM_SIZE},
      '{start_addr: DEBUG_ADDR, end_addr: DEBUG_ADDR + DEBUG_SIZE}
  };
  // DEBUG MODULE SYSTEM_BUS_ACCESS (dm_sba) memory map
  typedef enum {
    DM_SBA_IMEM_IDX,  //instructions
    DM_SBA_DMEM_IDX,  //data
    DM_SBA_SMEM_IDX,  //stack
    DM_SBA_MMIO_IDX,   // memory mapped I/O
    DM_SBA_SPM_IDX,   // scratchpad memory
    DM_SBA_LAST_IDX
  } sba_map_idx_t;

  // 
  localparam addr_range_t dm_sba_map[DM_SBA_LAST_IDX] = '{
      '{start_addr: IMEM_ADDR, end_addr: IMEM_ADDR + IMEM_SIZE},
      '{start_addr: DMEM_ADDR, end_addr: DMEM_ADDR + DMEM_SIZE},
      '{start_addr: SMEM_ADDR, end_addr: SMEM_ADDR + SMEM_SIZE},
      '{start_addr: MMIO_ADDR, end_addr: MMIO_ADDR_END},
      '{start_addr: SPM_NARROW_ADDR, end_addr: SPM_NARROW_ADDR + SPM_NARROW_SIZE}
      
  };
 `else
    // If debug module is not enabled, define empty parameters
  typedef enum {
    INSTR_MEM_IDX,
    INSTR_LAST_IDX
  } instr_map_idx_t;
  
`endif
  /********************************************************/
  /**           Interface Definitions                   **/
  /*******************************************************/

  // === Data port ===
  isolde_tcdm_if tcdm_core_data ();
  isolde_tcdm_if tcdm_dmem_muxed ();
  isolde_tcdm_if redmule_ctrl ();  // HWE peripheral  interface

  // === stack memory port ===
  isolde_tcdm_if tcdm_stack_muxed ();

  // === instruction memory port ===
  isolde_tcdm_if tcdm_core_inst ();
  isolde_tcdm_if tcdm_imem_muxed ();

  // === debugger module ports ===
  isolde_tcdm_if tcdm_dm_periph ();
  isolde_tcdm_if tcdm_dm_sba ();

  // === CPU -> SPM-s ports ===
  isolde_tcdm_if tcdm_spm_hwe[N_REDMULE_TILES] ();
  isolde_tcdm_if tcdm_spm_dma_muxed ();

// === Data sub-network on Chip NoC interfaces ===
  isolde_tcdm_pkg::req_t noc_spm_reqs[N_REDMULE_TILES];
  isolde_tcdm_pkg::rsp_t noc_spm_rsps[N_REDMULE_TILES];

  // === Data Network on Chip NoC interfaces ===
  isolde_tcdm_pkg::req_t noc_data_reqs[LAST_IDX];
  isolde_tcdm_pkg::rsp_t noc_data_rsps[LAST_IDX];
  // === Instruction Network on Chip NoC interfaces ===
  isolde_tcdm_pkg::req_t noc_instr_reqs[INSTR_LAST_IDX];
  isolde_tcdm_pkg::rsp_t noc_instr_rsps[INSTR_LAST_IDX];

`ifdef TARGET_RV_DEBUG
  // === Debug module System Bus Access (dm_sba) Network on Chip NoC interfaces ===
  isolde_tcdm_pkg::req_t noc_dm_sba_reqs[DM_SBA_LAST_IDX];
  isolde_tcdm_pkg::rsp_t noc_dm_sba_rsps[DM_SBA_LAST_IDX];
`endif

  // === CV-X-IF ===
  isolde_cv_x_if #(
      .X_NUM_RS   (isolde_cv_x_if_pkg::X_NUM_RS),
      .X_ID_WIDTH (isolde_cv_x_if_pkg::X_ID_WIDTH),
      .X_MEM_WIDTH(isolde_cv_x_if_pkg::X_MEM_WIDTH),
      .X_RFR_WIDTH(isolde_cv_x_if_pkg::X_RFR_WIDTH),
      .X_RFW_WIDTH(isolde_cv_x_if_pkg::X_RFW_WIDTH)
  ) itf_core_xif ();
  isolde_cv_x_if #(
      .X_NUM_RS   (isolde_cv_x_if_pkg::X_NUM_RS),
      .X_ID_WIDTH (isolde_cv_x_if_pkg::X_ID_WIDTH),
      .X_MEM_WIDTH(isolde_cv_x_if_pkg::X_MEM_WIDTH),
      .X_RFR_WIDTH(isolde_cv_x_if_pkg::X_RFR_WIDTH),
      .X_RFW_WIDTH(isolde_cv_x_if_pkg::X_RFW_WIDTH)
  ) itf_hwe_xif[N_REDMULE_TILES] ();

  /********************************************************/
  /**           Router(s)                                **/
  /*******************************************************/

  isolde_router #(
      .N_RULES(NoRules),
      .ADDR_RANGES(addr_map)
  ) i_isolde_data_router (
      .clk_i,
      .rst_ni,
      .tcdm_slave_i(tcdm_core_data),
      .req_o       (noc_data_reqs),
      .rsp_i       (noc_data_rsps)
  );
    
    

  isolde_tile_router #(
       .START_ADDR(SPM_NARROW_ADDR_BASE),  // Set start address
       .END_ADDR(SPM_NARROW_ADDR_BASE+SPM_NARROW_SIZE ),  // Set end address
       .N_TILES(N_REDMULE_TILES)      
    ) i_isolde_tile_router (
      .clk_i,
      .rst_ni,
      .issue_if(itf_core_xif),
      .req_i(tcdm_spm_dma_muxed.req),
      .rsp_o(tcdm_spm_dma_muxed.rsp),
      .req_o       (noc_spm_reqs),
      .rsp_i       (noc_spm_rsps)
  );
`ifdef TARGET_RV_DEBUG

  isolde_router #(
      .N_RULES(INSTR_LAST_IDX),
      .ADDR_RANGES(instr_map)
  ) i_isolde_instr_router (
      .clk_i,
      .rst_ni,
      .tcdm_slave_i(tcdm_core_inst),
      .req_o       (noc_instr_reqs),
      .rsp_i       (noc_instr_rsps)
  );

  isolde_router #(
      .N_RULES(DM_SBA_LAST_IDX),
      .ADDR_RANGES(dm_sba_map)
  ) i_isolde_dm_sba_router (
      .clk_i,
      .rst_ni,
      .tcdm_slave_i(tcdm_dm_sba),
      .req_o       (noc_dm_sba_reqs),
      .rsp_i       (noc_dm_sba_rsps)
  );
`else
    // If debug module is not enabled, tie off dm_sba NoC interfaces
    assign  noc_instr_reqs[INSTR_MEM_IDX]  = tcdm_core_inst.req;
    assign  tcdm_core_inst.rsp = noc_instr_rsps[INSTR_MEM_IDX] ;
`endif


  /********************************************************/
  /**           memory mapped I/O                        **/
  /*******************************************************/
      
aida_io #(
    .MMIO_ADDR(MMIO_ADDR)
) i_aida_io(
    .clk_i,
    .rst_ni,
    //
    .pads_o(pads_o),
    //
`ifdef TARGET_RV_DEBUG  
    .dm_sba_req(noc_dm_sba_reqs[DM_SBA_MMIO_IDX]),
    .dm_sba_rsp(noc_dm_sba_rsps[DM_SBA_MMIO_IDX]),
`endif    
    //  
    .data_req(noc_data_reqs[MMIO_IDX]),
    .data_rsp(noc_data_rsps[MMIO_IDX])
`ifdef TARGET_VERILATOR
    ,.sim_exit_code_o,
    .sim_exit_valid_o    
`endif    
);


`ifdef TARGET_RV_DEBUG  
  /********************************************************/
  /**     RV Debug Module                                **/
  /*******************************************************/

  isolde_mux_tcdm i_mux_dm_periph (
      .clk_i,
      .rst_ni,
      .req_2_i(noc_data_reqs[DEBUG_IDX]),
      .req_1_i(noc_instr_reqs[INSTR_DEBUG_IDX]),
      .rsp_2_o(noc_data_rsps[DEBUG_IDX]),
      .rsp_1_o(noc_instr_rsps[INSTR_DEBUG_IDX]),
      .tcdm_master_o(tcdm_dm_periph)
  );

  isolde_mux_tcdm i_mux_dm_sb_imem (
      .clk_i,
      .rst_ni,
      .req_1_i(noc_dm_sba_reqs[DM_SBA_IMEM_IDX]),
      .req_2_i(noc_instr_reqs[INSTR_MEM_IDX]),
      .rsp_1_o(noc_dm_sba_rsps[DM_SBA_IMEM_IDX]),
      .rsp_2_o(noc_instr_rsps[INSTR_MEM_IDX]),
      .tcdm_master_o(tcdm_imem_muxed)
  );


  isolde_mux_tcdm i_mux_dm_sb_dmem (
      .clk_i,
      .rst_ni,
      .req_1_i(noc_dm_sba_reqs[DM_SBA_DMEM_IDX]),
      .req_2_i(noc_data_reqs[DATA_IDX]),
      .rsp_1_o(noc_dm_sba_rsps[DM_SBA_DMEM_IDX]),
      .rsp_2_o(noc_data_rsps[DATA_IDX]),
      .tcdm_master_o(tcdm_dmem_muxed)
  );

  isolde_mux_tcdm i_mux_dm_sb_stack (
      .clk_i,
      .rst_ni,
      .req_1_i(noc_dm_sba_reqs[DM_SBA_SMEM_IDX]),
      .req_2_i(noc_data_reqs[STACK_IDX]),
      .rsp_1_o(noc_dm_sba_rsps[DM_SBA_SMEM_IDX]),
      .rsp_2_o(noc_data_rsps[STACK_IDX]),
      .tcdm_master_o(tcdm_stack_muxed)
  );


  isolde_mux_tcdm i_mux_dm_sb_spm (
      .clk_i,
      .rst_ni,
      .req_1_i(noc_dm_sba_reqs[DM_SBA_SPM_IDX]),
      .req_2_i(noc_data_reqs[SPM_IDX]),
      .rsp_1_o(noc_dm_sba_rsps[DM_SBA_SPM_IDX]),
      .rsp_2_o(noc_data_rsps[SPM_IDX]),
      .tcdm_master_o(tcdm_spm_dma_muxed)
  );

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
`else
// === tcdm_spm_dma_muxed assignment ===
    
    assign tcdm_spm_dma_muxed.req = noc_data_reqs[SPM_IDX];
    assign noc_data_rsps[SPM_IDX] = tcdm_spm_dma_muxed.rsp;

// === tcdm_dmem_muxed assignment ===
    assign tcdm_dmem_muxed.req = noc_data_reqs[DATA_IDX];
    assign noc_data_rsps[DATA_IDX] = tcdm_dmem_muxed.rsp;
// === tcdm_imem_muxed assignment ===
    assign tcdm_imem_muxed.req = noc_instr_reqs[INSTR_MEM_IDX];
    assign noc_instr_rsps[INSTR_MEM_IDX] = tcdm_imem_muxed.rsp;    
// === tcdm_stack_muxed assignment ===
    assign tcdm_stack_muxed.req = noc_data_reqs[STACK_IDX];
    assign noc_data_rsps[STACK_IDX] = tcdm_stack_muxed.rsp;    
`endif

  /********************************************************/
  /**     ADDRESS SHIM FOR TILES                        **/
  /*******************************************************/
    generate
    for (genvar i = 0; i < N_REDMULE_TILES; i++) begin : gen_tile_addr_shim
      
        assign tcdm_spm_hwe[i].req = noc_spm_reqs[i];
        assign noc_spm_rsps[i] = tcdm_spm_hwe[i].rsp;
  
    end
  endgenerate

  



  /********************************************************/
  /**     Data memory                                    **/
  /*******************************************************/

  isolde_addr_shim_wrp #(
      .START_ADDR(DMEM_ADDR),  // Set start address
      .END_ADDR(DMEM_ADDR + DMEM_SIZE)  // Set end address
  ) i_dmem_shim (
      .tcdm_slave_i (tcdm_dmem_muxed),
      .tcdm_master_o(aida_data_memory)
  );


  /********************************************************/
  /**     Instruction memory                             **/
  /*******************************************************/

  isolde_addr_shim_wrp #(
      .START_ADDR(IMEM_ADDR),  // Set start address
      .END_ADDR(IMEM_ADDR + IMEM_SIZE)  // Set end address
  ) i_imem_shim (
      .tcdm_slave_i (tcdm_imem_muxed),
      .tcdm_master_o(aida_instr_memory)
  );


  /********************************************************/
  /**     Stack memory                                   **/
  /*******************************************************/

  isolde_addr_shim_wrp #(
      .START_ADDR(SMEM_ADDR),  // Set start address
      .END_ADDR(SMEM_ADDR + SMEM_SIZE)  // Set end address
  ) i_stack_mem_shim (
      .tcdm_slave_i (tcdm_stack_muxed),
      .tcdm_master_o(aida_stack_memory)
  );


  /********************************************************/
  /**     BOOT ROM memory                                **/
  /*******************************************************/
`ifdef TARGET_RV_DEBUG  

    generate
    if (BootROMEnable) begin : boot_rom_block
        isolde_boot_rom #(
        .BASE_ADDR(ROM_BOOT_ADDR)
        ) i_aida_boot_rom (
        .clk_i(clk_i),
        .boot_req_i(noc_instr_reqs[BOOT_MEM_IDX]),
        .boot_rsp_o(noc_instr_rsps[BOOT_MEM_IDX])
        );
    end
    endgenerate
`endif

  
  /********************************************************/
  /**     CV-X-IF  logging                              **/
  /*******************************************************/
`ifdef TARGET_VERILATOR
  xif_monitor_issue xif_monitor_cpu_issue_i (
      .clk_i(clk_i),
      .issue_if(itf_core_xif.monitor_issue)
  );

  
  generate
    for (genvar i = 0; i < N_REDMULE_TILES; i++) begin : g_tile_monitor_issue
      xif_monitor_issue #(
          .FILENAME($sformatf("xif_tile_%0d_issue", i)),
          .NAME    ($sformatf("XIF_TILE_%0d", i)),
          .ID      (i)
      ) xif_monitor_tile_issue_i (
          .clk_i(clk_i),
          .issue_if(itf_hwe_xif[i].monitor_issue)
      );
    end
  endgenerate
`endif

  /********************************************************/
  /**     IBEX core                                     **/
  /*******************************************************/
`ifdef TARGET_VERILATOR
  ibex_top_tracing #(
`else    
  ibex_top #(
`endif   
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

      .hart_id_i        (32'b0),
      // First instruction executed is at 0x0 + 0x80
      .boot_addr_i      (BOOT_ADDR),
      // === Instruction memory interface
      .instr_req_o      (tcdm_core_inst.req.req),
      .instr_gnt_i      (tcdm_core_inst.rsp.gnt),
      .instr_rvalid_i   (tcdm_core_inst.rsp.valid),
      .instr_addr_o     (tcdm_core_inst.req.addr),
      .instr_rdata_i    (tcdm_core_inst.rsp.data),
      .instr_rdata_intg_i     ('0),
      .instr_err_i            (1'b0),
      // === Data memory interface
      .data_req_o       (tcdm_core_data.req.req),
      .data_gnt_i       (tcdm_core_data.rsp.gnt),
      .data_rvalid_i    (tcdm_core_data.rsp.valid),
      .data_addr_o      (tcdm_core_data.req.addr),
      .data_be_o        (tcdm_core_data.req.be),
      .data_we_o        (tcdm_core_data.req.we),
      .data_wdata_o     (tcdm_core_data.req.data),
      .data_wdata_intg_o(),
      .data_rdata_i     (tcdm_core_data.rsp.data),
      .data_rdata_intg_i('0),
      .data_err_i       (1'b0),

      .irq_software_i(|core_evt_cpu),
      .irq_timer_i   (1'b0),
      .irq_external_i(1'b0),
      .irq_fast_i    ('0),
      .irq_nm_i      (1'b0),

      .scramble_key_valid_i('0),
      .scramble_key_i      ('0),
      .scramble_nonce_i    ('0),
      .scramble_req_o      (),

      .debug_req_i        (debug_req[0]),
      .crash_dump_o       (),
      .double_fault_seen_o(),

      .fetch_enable_i        ({ibex_pkg::IbexMuBiWidth{fetch_enable_i}}),
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

  /********************************************************/
  /**     Hardware Engine (HWE) Cluster                  **/
  /*******************************************************/
  
  `ifdef TARGET_REDMULE_COMPLEX
 

isolde_xif_relay #(
    .NC(NC)
) i_xif_relay (
    .clk_i,
    .rst_ni,
    .cpu_xif_issue   (itf_core_xif.coproc_issue),
    .cpu_xif_result  (itf_core_xif.coproc_result),
    .tile_xif_issue  (itf_hwe_xif.cpu_issue),
    .tile_xif_result (itf_hwe_xif.cpu_result),
    .tile_evt_i(tile_evt),
    .core_evt_o(core_evt)
);
   assign core_evt_mask = itf_core_xif.interrupt_enable_mask;
   assign itf_core_xif.cluster_status.status ={1'b0, tile_busy};
   assign itf_core_xif.cluster_status.ip ={1'b0,core_evt};
   assign itf_core_xif.cluster_status.ip_wr_en =1'b1;
   assign itf_core_xif.cluster_status.status_wr_en =1'b1;


//


    generate
    for (genvar i = 0; i < N_REDMULE_TILES; i++) begin : gen_tile
      // Instantiate memory bank
    isolde_tile #(
        .ID(i)
    ) i_tile(
      .clk_i         (clk_i),
      .rst_ni        (rst_ni),
      .fetch_enable_i(fetch_enable_i),
      .evt_o         (tile_evt[i]),
      .busy_o(tile_busy[i]),
      .tcdm_spm_dma    (tcdm_spm_hwe[i]),
      .xif_issue_if_i     (itf_hwe_xif[i].coproc_issue),
      .xif_result_if_o    (itf_hwe_xif[i].coproc_result),
      .xif_compressed_if_i(itf_hwe_xif[i].coproc_compressed),
      .xif_mem_if_o       (itf_hwe_xif[i].coproc_mem)
  );

    end
  endgenerate

`elsif TARGET_REDMULE_HWPE

'error "TARGET_REDMULE_HWPE is not supported in this version of Isolde-SOC"
`elsif TARGET_COHEN_CVXIF

`error "TARGET_COHEN_CVXIF is not supported in this version of Isolde-SOC"

`endif





endmodule
