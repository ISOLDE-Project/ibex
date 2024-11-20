// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Yvan Tortorella <yvan.tortorella@unibo.it>
//

timeunit 1ps; timeprecision 1ps;

module tb_tca_system
  import redmule_pkg::*;
#(
    parameter TCP = 1.0ns,  // clock period, 1 GHz clock
    parameter TA  = 0.2ns,  // application time
    parameter TT  = 0.8ns   // test time
) (
    input logic clk_i,
    input logic rst_ni,
    input logic fetch_enable_i
);

  // parameters
  localparam int unsigned PROB_STALL = 0;
  localparam int unsigned NC = 1;
  localparam int unsigned ID = 10;
  localparam int unsigned DW = redmule_pkg::DATA_W;
  localparam int unsigned MP = DW / 32;
  localparam int unsigned MEMORY_SIZE = 32'h30000;
  localparam int unsigned STACK_MEMORY_SIZE = 32'h30000;
  localparam int unsigned PULP_XPULP = 1;
  localparam int unsigned FPU = 0;
  localparam int unsigned PULP_ZFINX = 0;
  localparam logic [31:0] BASE_ADDR = 32'h1c000000;
  localparam logic [31:0] HWPE_ADDR_BASE_BIT = 20;

  int          fh; //filehandle
  //
  /* see cv32e40p/bsp/link.ld
MEMORY
{
    instrram    : ORIGIN = 0x00100000, LENGTH = 0x8000
    dataram     : ORIGIN = 0x00110000, LENGTH = 0x30000
    stack       : ORIGIN = 0x00140000, LENGTH = 0x30000
}
*/
  localparam logic [31:0] IMEM_ADDR = 32'h00100000;
  localparam int unsigned IMEM_SIZE = 32'h08000;
  localparam logic [31:0] DMEM_ADDR = 32'h00110000;
  localparam int unsigned DMEM_SIZE = 32'h30000;
  localparam logic [31:0] SMEM_ADDR = 32'h00140000;
  localparam int unsigned SMEM_SIZE = 32'h30000;
  localparam int unsigned GMEM_SIZE = SMEM_ADDR + SMEM_SIZE - IMEM_ADDR;
  //  see reset vector in cv32e40p/bsp/crt0.S
  localparam logic [31:0] BOOT_ADDR = 32'h00100080;
    //see cv32e40p/bsp/simple_system_regs.h
  localparam logic [31:0] MMIO_ADDR = 32'h80000000;
  localparam logic [31:0] MMADDR_EXIT = MMIO_ADDR + 32'h0;
  localparam logic [31:0] MMADDR_PRINT = MMIO_ADDR + 32'h4;

  // global signals
  string stim_instr, stim_data;
  logic test_mode;
    logic [  31:0]       cycle_counter;
  logic                mmio_rvalid;
  logic [  31:0]       mmio_rdata;
  logic redmule_busy;

  //hwpe_stream_intf_tcdm instr[0:0] (.clk(clk_i));
  hwpe_stream_intf_tcdm stack[0:0] (.clk(clk_i));
  hwpe_stream_intf_tcdm tcdm[MP+1:0] (.clk(clk_i));

  logic [NC-1:0][ 1:0] evt;

  logic [MP-1:0]       tcdm_req;
  logic [MP-1:0]       tcdm_gnt;
  logic [MP-1:0][31:0] tcdm_add;
  logic [MP-1:0]       tcdm_wen;
  logic [MP-1:0][ 3:0] tcdm_be;
  logic [MP-1:0][31:0] tcdm_data;
  logic [MP-1:0][31:0] tcdm_r_data;
  logic [MP-1:0]       tcdm_r_valid;
  logic                tcdm_r_opc;
  logic                tcdm_r_user;

  logic                periph_req;
  logic                periph_gnt;
  logic [  31:0]       periph_add;
  logic                periph_wen;
  logic [   3:0]       periph_be;
  logic [  31:0]       periph_data;
  logic [ID-1:0]       periph_id;
  logic [  31:0]       periph_r_data;
  logic                periph_r_valid;
  logic [ID-1:0]       periph_r_id;

  logic                instr_req;
  logic                instr_gnt;
  logic                instr_rvalid;
  logic [  31:0]       instr_addr;
  logic [  31:0]       instr_rdata;

  logic                data_req;
  logic                data_gnt;
  logic                data_rvalid;
  logic                data_we;
  logic [   3:0]       data_be;
  logic [  31:0]       data_addr;
  logic [  31:0]       data_wdata;
  logic [  31:0]       data_rdata;
  logic                data_err;
  logic                core_sleep;

  typedef struct packed {
    logic        req;
    logic [31:0] addr;
  } core_inst_req_t;

  typedef struct packed {
    logic        gnt;
    logic        valid;
    logic [31:0] data;
  } core_inst_rsp_t;

  typedef struct packed {
    logic req;
    logic we;
    logic [3:0] be;
    logic [31:0] addr;
    logic [31:0] data;
  } core_data_req_t;

  typedef struct packed {
    logic gnt;
    logic valid;
    logic [31:0] data;
  } core_data_rsp_t;

  hci_core_intf #(.DW(DW)) redmule_tcdm (.clk(clk_i));

  core_inst_req_t core_inst_req;
  core_inst_rsp_t core_inst_rsp;

  core_data_req_t core_data_req;
  core_data_rsp_t core_data_rsp;

  // bindings
  always_comb begin : bind_periph
    periph_req     = '0;
    periph_add     = core_data_req.addr;
    periph_wen     = ~core_data_req.we;
    periph_be      = core_data_req.be;
    periph_data    = core_data_req.data;
    periph_id      = '0;
    periph_r_valid = '0;
  end

  always_comb begin : bind_instrs
    tcdm[MP+1].req = core_inst_req.req;
    tcdm[MP+1].add = core_inst_req.addr;
    tcdm[MP+1].wen = 1'b1;
    tcdm[MP+1].be = '0;
    tcdm[MP+1].data = '0;
    core_inst_rsp.gnt = tcdm[MP+1].gnt;
    core_inst_rsp.valid = tcdm[MP+1].r_valid;
    core_inst_rsp.data = tcdm[MP+1].r_data;
  end

  always_comb begin : bind_stack
    stack[0].req  = core_data_req.req & (core_data_req.addr >= SMEM_ADDR) &
                                        (core_data_req.addr < SMEM_ADDR+SMEM_SIZE) ;
    stack[0].add = core_data_req.addr;
    stack[0].wen = ~core_data_req.we;
    stack[0].be = core_data_req.be;
    stack[0].data = core_data_req.data;
  end

  
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) mmio_rvalid <= '0;
    else mmio_rvalid <= core_data_req.req & (core_data_req.addr >= MMIO_ADDR);
  end

  for (genvar ii = 0; ii < MP; ii++) begin : tcdm_binding
    assign tcdm[ii].req     = redmule_tcdm.req;
    assign tcdm[ii].add     = redmule_tcdm.add + ii * 4;
    assign tcdm[ii].wen     = redmule_tcdm.wen;
    assign tcdm[ii].be      = redmule_tcdm.be[(ii+1)*4-1:ii*4];
    assign tcdm[ii].data    = redmule_tcdm.data[(ii+1)*32-1:ii*32];
    assign tcdm_gnt[ii]     = tcdm[ii].gnt;
    assign tcdm_r_valid[ii] = tcdm[ii].r_valid;
    assign tcdm_r_data[ii]  = tcdm[ii].r_data;
  end
  assign redmule_tcdm.gnt = &tcdm_gnt;
  assign redmule_tcdm.r_data = {tcdm_r_data};
  assign redmule_tcdm.r_valid = &tcdm_r_valid;
  assign redmule_tcdm.r_opc = '0;
  assign redmule_tcdm.r_user = '0;

  assign tcdm[MP].req  = core_data_req.req &
                         (core_data_req.addr >= DMEM_ADDR) &
                         (core_data_req.addr <  DMEM_ADDR + DMEM_SIZE) ;
  assign tcdm[MP].add = core_data_req.addr;
  assign tcdm[MP].wen = ~core_data_req.we;
  assign tcdm[MP].be = core_data_req.be;
  assign tcdm[MP].data = core_data_req.data;

  assign core_data_rsp.gnt = periph_req ?
                             periph_gnt : stack[0].req ?
                                          stack[0].gnt : tcdm[MP].req ?
                                                         tcdm[MP].gnt : '1;

  assign core_data_rsp.data = periph_r_valid   ? periph_r_data    :
                              stack[0].r_valid ? stack[0].r_data  :
                                                 tcdm[MP].r_valid ? tcdm[MP].r_data : 
                                                                    mmio_rvalid ? mmio_rdata: '0;
  assign core_data_rsp.valid = periph_r_valid | stack[0].r_valid | tcdm[MP].r_valid | mmio_rvalid;

  // tb_dummy_memory  #(
  //   .MP             ( MP + 1        ),
  //   .MEMORY_SIZE    ( MEMORY_SIZE   ),
  //   .BASE_ADDR      ( 32'h1c010000  ),
  //   .PROB_STALL     ( PROB_STALL    ),
  //   .TCP            ( TCP           ),
  //   .TA             ( TA            ),
  //   .TT             ( TT            )
  // ) i_dummy_dmemory (
  //   .clk_i          ( clk_i         ),
  //   .rst_ni         ( rst_ni        ),
  //   .clk_delayed_i  ( '0            ),
  //   .randomize_i    ( 1'b0          ),
  //   .enable_i       ( 1'b1          ),
  //   .stallable_i    ( 1'b1          ),
  //   .tcdm           ( tcdm          )
  // );

  tb_tcdm_verilator #(
      .MP         (MP + 1),
      .MEMORY_SIZE(GMEM_SIZE),
      .BASE_ADDR  (IMEM_ADDR)
  ) i_dummy_dmemory (
      .clk_i   (clk_i),
      .rst_ni  (rst_ni),
      .enable_i(1'b1),
      .tcdm    (tcdm[MP:0])
  );


  tb_tcdm_verilator #(
      .MP         (1),
      .MEMORY_SIZE(GMEM_SIZE),
      .BASE_ADDR  (IMEM_ADDR)
  ) i_dummy_imemory (
      .clk_i   (clk_i),
      .rst_ni  (rst_ni),
      .enable_i(1'b1),
      .tcdm    (tcdm[MP+1:MP+1])
  );

  tb_tcdm_verilator #(
      .MP         (1),
      .MEMORY_SIZE(SMEM_SIZE),
      .BASE_ADDR  (SMEM_ADDR)
  ) i_dummy_stack_memory (
      .clk_i   (clk_i),
      .rst_ni  (rst_ni),
      .enable_i(1'b1),
      .tcdm    (stack)
  );

  redmule_complex #(
      .CoreType       (redmule_pkg::CV32X),  // CV32E40P, CV32E40X, IBEX, SNITCH, CVA6
      .ID_WIDTH       (ID),
      .N_CORES        (NC),
      .DW             (DW),                  // TCDM port dimension (in bits)
      .MP             (DW / 32),
      .NumIrqs        (0),
      .AddrWidth      (32),
      .core_data_req_t(core_data_req_t),
      .core_data_rsp_t(core_data_rsp_t),
      .core_inst_req_t(core_inst_req_t),
      .core_inst_rsp_t(core_inst_rsp_t)
  ) i_dut (
      .clk_i          (clk_i),
      .rst_ni         (rst_ni),
      .test_mode_i    (test_mode),
      .fetch_enable_i (fetch_enable_i),
      .boot_addr_i    (BOOT_ADDR),
      .irq_i          ('0),
      .irq_id_o       (),
      .irq_ack_o      (),
      .core_sleep_o   (core_sleep),
      .core_inst_rsp_i(core_inst_rsp),
      .core_inst_req_o(core_inst_req),
      .core_data_rsp_i(core_data_rsp),
      .core_data_req_o(core_data_req),
      .tcdm           (redmule_tcdm)
  );

    task dump_ctrl_fsm();
    $fwrite(fh, "Simulation Time: %t\n", $time); // Print the current simulation time
    $fwrite(fh, "ctrl_busy: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.controller_i.ctrl_fsm_o.ctrl_busy);
    // $fwrite(fh, "instr_req: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.controller_i.ctrl_fsm_o.instr_req);
    // $fwrite(fh, "pc_set: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.controller_i.ctrl_fsm_o.pc_set);
    // $fwrite(fh, "pc_set_clicv: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.controller_i.ctrl_fsm_o.pc_set_clicv);
    // $fwrite(fh, "pc_set_tbljmp: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.controller_i.ctrl_fsm_o.pc_set_tbljmp);
    // $fwrite(fh, "pc_mux: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.controller_i.ctrl_fsm_o.pc_mux);
    // $fwrite(fh, "mtvec_pc_mux: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.controller_i.ctrl_fsm_o.mtvec_pc_mux);
    // $fwrite(fh, "mtvt_pc_mux: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.controller_i.ctrl_fsm_o.mtvt_pc_mux);
    // $fwrite(fh, "nmi_mtvec_index: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.controller_i.ctrl_fsm_o.nmi_mtvec_index);
    // $fwrite(fh, "block_data_addr: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.controller_i.ctrl_fsm_o.block_data_addr);
    // $fwrite(fh, "irq_ack: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.controller_i.ctrl_fsm_o.irq_ack);
    // $fwrite(fh, "irq_id: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.controller_i.ctrl_fsm_o.irq_id);
    // $fwrite(fh, "irq_level: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.controller_i.ctrl_fsm_o.irq_level);
    // $fwrite(fh, "irq_priv: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.controller_i.ctrl_fsm_o.irq_priv);
    // $fwrite(fh, "irq_shv: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.controller_i.ctrl_fsm_o.irq_shv);
    // $fwrite(fh, "dbg_ack: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.controller_i.ctrl_fsm_o.dbg_ack);
    // $fwrite(fh, "debug_mode_if: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.controller_i.ctrl_fsm_o.debug_mode_if);
    // $fwrite(fh, "debug_mode: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.controller_i.ctrl_fsm_o.debug_mode);
    // $fwrite(fh, "debug_cause: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.controller_i.ctrl_fsm_o.debug_cause);
    // $fwrite(fh, "debug_csr_save: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.controller_i.ctrl_fsm_o.debug_csr_save);
    // $fwrite(fh, "debug_trigger_hit: %h\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.controller_i.ctrl_fsm_o.debug_trigger_hit);
    // $fwrite(fh, "debug_trigger_hit_update: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.controller_i.ctrl_fsm_o.debug_trigger_hit_update);
    // $fwrite(fh, "debug_no_sleep: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.controller_i.ctrl_fsm_o.debug_no_sleep);
    // $fwrite(fh, "debug_havereset: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.controller_i.ctrl_fsm_o.debug_havereset);
    // $fwrite(fh, "debug_running: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.controller_i.ctrl_fsm_o.debug_running);
    // $fwrite(fh, "debug_halted: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.controller_i.ctrl_fsm_o.debug_halted);
    $fwrite(fh, "wake_from_sleep: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.controller_i.ctrl_fsm_o.wake_from_sleep);
    $fwrite(fh, "pipe_pc: %h\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.controller_i.ctrl_fsm_o.pipe_pc);
    // $fwrite(fh, "csr_cause: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.controller_i.ctrl_fsm_o.csr_cause);
    // $fwrite(fh, "csr_restore_mret: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.controller_i.ctrl_fsm_o.csr_restore_mret);
    // $fwrite(fh, "csr_restore_mret_ptr: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.controller_i.ctrl_fsm_o.csr_restore_mret_ptr);
    // $fwrite(fh, "csr_restore_dret: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.controller_i.ctrl_fsm_o.csr_restore_dret);
    // $fwrite(fh, "csr_save_cause: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.controller_i.ctrl_fsm_o.csr_save_cause);
    // $fwrite(fh, "pending_nmi: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.controller_i.ctrl_fsm_o.pending_nmi);
    // $fwrite(fh, "mhpmevent: %h\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.controller_i.ctrl_fsm_o.mhpmevent);
    // $fwrite(fh, "halt_if: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.controller_i.ctrl_fsm_o.halt_if);
    // $fwrite(fh, "halt_id: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.controller_i.ctrl_fsm_o.halt_id);
    // $fwrite(fh, "halt_ex: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.controller_i.ctrl_fsm_o.halt_ex);
    // $fwrite(fh, "halt_wb: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.controller_i.ctrl_fsm_o.halt_wb);
    // $fwrite(fh, "halt_limited_wb: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.controller_i.ctrl_fsm_o.halt_limited_wb);
    // $fwrite(fh, "kill_if: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.controller_i.ctrl_fsm_o.kill_if);
    // $fwrite(fh, "kill_id: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.controller_i.ctrl_fsm_o.kill_id);
    // $fwrite(fh, "kill_ex: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.controller_i.ctrl_fsm_o.kill_ex);
    // $fwrite(fh, "kill_wb: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.controller_i.ctrl_fsm_o.kill_wb);
    // $fwrite(fh, "kill_xif: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.controller_i.ctrl_fsm_o.kill_xif);
    // $fwrite(fh, "exception_in_wb: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.controller_i.ctrl_fsm_o.exception_in_wb);
    // $fwrite(fh, "exception_cause_wb: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.controller_i.ctrl_fsm_o.exception_cause_wb);
    //$fwrite(fh, "xif_commit_if.result_valid: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.controller_i.xif_commit_if.result_valid);
  //$fwrite(fh, "xif_commit_if.result_ready: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.controller_i.xif_commit_if.result_ready);
    $fwrite(fh, "xif_csr_error_i: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.controller_i.xif_csr_error_i);
  endtask

task dump_core_sleep_unit();
   $fwrite(fh, "Simulation Time: %t\n", $time); // Print the current simulation time
  $fwrite(fh, "core_sleep_o: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.sleep_unit_i.core_sleep_o);
  $fwrite(fh, "fetch_enable_i: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.sleep_unit_i.fetch_enable_i);
  $fwrite(fh, "fetch_enable_o: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.sleep_unit_i.fetch_enable_o);

  // Core status
  $fwrite(fh, "if_busy_i: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.sleep_unit_i.if_busy_i);
  $fwrite(fh, "lsu_busy_i: %b\n", tb_tca_system.i_dut.gen_cv32e40x.i_core.sleep_unit_i.lsu_busy_i);
  
  endtask





    
  //   enum logic [1:0] {NONE,READ,WRITE } local_wen;
  //   always_ff @(posedge clk_i) begin
  //     if (~rst_ni) begin
  //         local_wen =NONE;
  //     end
  //     if (redmule_tcdm.req) begin
  //       if (redmule_tcdm.gnt) begin
  //         if (redmule_tcdm.wen) 
  //           // Log read operation
  //           $fwrite(fh, "%t : read address=%h\n", $time, redmule_tcdm.add);
  //         else begin
  //           $fwrite(fh, "%t : write address=%h\n", $time, redmule_tcdm.add);
  //         end
  //         if (local_wen == READ & redmule_tcdm.r_valid) begin
  //           $fwrite(fh, "%t : r_data=%h\n", $time, redmule_tcdm.r_data);
  //           $fwrite(fh, "%t : r_opc=%h\n", $time, redmule_tcdm.r_opc);
  //           $fwrite(fh, "%t : r_user=%h\n", $time, redmule_tcdm.r_user);
  //           end 
  //         if(local_wen == WRITE)
  //           $fwrite(fh, "%t : data=%h\n", $time, redmule_tcdm.data);
  //         // Common fields
  //         $fwrite(fh, "%t : be=%h\n", $time, redmule_tcdm.be);
  //         $fwrite(fh, "%t : boffs=%h\n", $time, redmule_tcdm.boffs);
  //         $fwrite(fh, "%t : user=%h\n", $time, redmule_tcdm.user);
  //         local_wen = redmule_tcdm.wen ? READ:WRITE;
  //       end else begin
  //         local_wen =NONE;
  //       end

  //   end
  // end

// Declare the task with an input parameter for errors
task endSimulation(input int errors);
    if (errors != 0) begin
        $display("[TB TCA] @ t=%0t - Fail!", $time);
        $error("[TB TCA] @ t=%0t - errors=%08x", $time, errors);
    end else begin
        $display("[TB TCA] @ t=%0t - Success!", $time);
        $display("[TB TCA] @ t=%0t - errors=%08x", $time, errors);
    end
    $finish;
endtask

// Use the task with core_data_req.data
always_ff @(posedge clk_i) begin
    if (~rst_ni) cycle_counter <= '0;
    else cycle_counter <= cycle_counter + 1;

    if ((core_data_req.addr == MMADDR_EXIT) && core_data_req.req ) begin
        if (core_data_req.we ) 
           endSimulation(core_data_req.data); 
        else
           mmio_rdata <= cycle_counter;
    end
    if ((core_data_req.addr == MMADDR_PRINT) &&
        (core_data_req.we & core_data_req.req )) begin
        $write("%c", core_data_req.data);
    end
    dump_ctrl_fsm();
    dump_core_sleep_unit();
end


  initial begin
    integer id;
    int cnt_rd, cnt_wr;
    fh = $fopen("rtl_debug_trace.log", "w");
    // Load instruction and data memory
    if (!$value$plusargs("STIM_INSTR=%s", stim_instr)) begin
      $display("No STIM_INSTR specified");
      $finish;
    end else begin
      $display("[TESTBENCH] @ t=%0t: loading %0s into imemory", $time, stim_instr);
      $readmemh(stim_instr, tb_tca_system.i_dummy_imemory.memory);
    end

    if (!$value$plusargs("STIM_DATA=%s", stim_data)) begin
      $display("No STIM_DATA specified");
      $finish;
    end else begin
      $display("[TESTBENCH] @ t=%0t: loading %0s into dmemory", $time, stim_data);
      $readmemh(stim_data, tb_tca_system.i_dummy_dmemory.memory);
    end

    test_mode = 1'b0;

  end

  // close output file for writing
  final begin
   
      $fclose(fh);
   
  end
endmodule  // tb_tca_system
