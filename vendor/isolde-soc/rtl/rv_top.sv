module rv_top
import ibex_pkg::*;
import aida_lca_package::*;
#(
 parameter  BootROMEnable = 1'b1
)(
   // Clock and Reset
    input logic clk_i,
    input logic rst_ni,
    // === Instruction memory interface
    output logic        instr_req_o,
    input  logic        instr_gnt_i,
    input  logic        instr_rvalid_i,
    output logic [31:0] instr_addr_o,
    input  logic [31:0] instr_rdata_i,
    // === Data memory interface
    output logic        data_req_o,
    input  logic        data_gnt_i,
    input  logic        data_rvalid_i,
    output logic        data_we_o,
    output logic [ 3:0] data_be_o,
    output logic [31:0] data_addr_o,
    output logic [31:0] data_wdata_o,
    input  logic [31:0] data_rdata_i,
    // === Interrupt inputs
    input logic        irq_software_i,
    // === Debug Interface
    input  logic        debug_req_i,
    // === CPU Control Signals
    input  ibex_mubi_t fetch_enable_i,
    output logic       core_sleep_o
);
    localparam bit          PMPEnable        = 1'b0;
    localparam int unsigned PMPGranularity   = 0;
    localparam int unsigned PMPNumRegions    = 4;
    localparam int unsigned MHPMCounterNum   = 0;
    localparam int unsigned MHPMCounterWidth = 40;
    localparam bit          RV32E            = 1'b0;
    localparam rv32m_e      RV32M            = RV32MFast;
    localparam rv32b_e      RV32B            = RV32BNone;
    localparam regfile_e    RegFile          = RegFileFF;
    localparam bit          BranchTargetALU  = 1'b0;
    localparam bit          WritebackStage   = 1'b0;
    localparam bit          ICache           = 1'b0;
    localparam bit          ICacheECC        = 1'b0;
    localparam bit          BranchPredictor  = 1'b0;
    localparam bit          DbgTriggerEn     = 1'b0;
    localparam bit          SecureIbex       = 1'b0;
    localparam bit          ICacheScramble   = 1'b0;
    localparam int unsigned DmHaltAddr       = 32'h1A11_0800;
    localparam int unsigned DmExceptionAddr  = 32'h1A11_0808;

    logic [31:0] BOOT_ADDR;

   assign BOOT_ADDR =  BootROMEnable? ROM_BOOT_ADDR : RV_BOOT_ADDR;

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
      .clk_i ,
      .rst_ni,

      .test_en_i  (1'b0),
      .scan_rst_ni(1'b1),
      .ram_cfg_i  (prim_ram_1p_pkg::RAM_1P_CFG_DEFAULT),

      .hart_id_i        (32'b0),
      // First instruction executed is at 0x0 + 0x80
      .boot_addr_i      (BOOT_ADDR),
      // === Instruction memory interface
      .instr_req_o ,
      .instr_gnt_i ,
      .instr_rvalid_i   ,
      .instr_addr_o     ,
      .instr_rdata_i    ,
      .instr_rdata_intg_i     ('0),
      .instr_err_i            (1'b0),
      // === Data memory interface
      .data_req_o      ,
      .data_gnt_i       ,
      .data_rvalid_i    ,
      .data_addr_o      ,
      .data_be_o        ,
      .data_we_o       ,
      .data_wdata_o     ,
      .data_wdata_intg_o(),
      .data_rdata_i    ,
      .data_rdata_intg_i(),
      .data_err_i       (),

      .irq_software_i,
      .irq_timer_i   (1'b0),
      .irq_external_i(1'b0),
      .irq_fast_i    (1'b0),
      .irq_nm_i      (1'b0),

      .scramble_key_valid_i('0),
      .scramble_key_i      ('0),
      .scramble_nonce_i    ('0),
      .scramble_req_o      (),

      .debug_req_i       ,
      .crash_dump_o       (),
      .double_fault_seen_o(),

      .fetch_enable_i        ,
      .alert_minor_o         (),
      .alert_major_internal_o(),
      .alert_major_bus_o     (),
      .core_sleep_o         
  );


endmodule : rv_top