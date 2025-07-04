// Copyleft ISOLDE 2025

/* this is inspired from the hci_log_interconnect.sv file from https://github.com/pulp-platform/hci.git
 * original authors:
 * Francesco Conti <f.conti@unibo.it>
 *
 * Top level for the log interconnect
 */

import isolde_soc_package::*;

module isolde_log_interconnect
  import tcdm_interconnect_pkg::topo_e;
#(
    parameter int unsigned N_SLAVES  = 1,
    parameter int unsigned N_MASTERS = 9
) (
    input logic                 clk_i,
    input logic                 rst_n,
          isolde_tcdm_if.slave  s_cores[ N_SLAVES-1:0],
          isolde_tcdm_if.master m_mems [N_MASTERS-1:0]
);
  localparam int unsigned AWC = 32;  // Address Width Core
  localparam int unsigned AWM = 32;  // Address Width Memory
  localparam int unsigned DW = 32;  // Data Width
  localparam int unsigned UW = 0;  // User Width, not used in this interconnect
  localparam int unsigned BW = 8;  // Byte Width
  //localparam int unsigned IW  = 0;  // ID Width, not used in this interconnect

  // master side
  logic [ N_SLAVES-1:0]            cores_req;
  logic [ N_SLAVES-1:0][  AWC-1:0] cores_add;
  logic [ N_SLAVES-1:0]            cores_wen;
  logic [ N_SLAVES-1:0][UW+DW-1:0] cores_wdata;
  logic [ N_SLAVES-1:0][DW/BW-1:0] cores_be;
  logic [ N_SLAVES-1:0]            cores_gnt;
  logic [ N_SLAVES-1:0]            cores_r_valid;
  logic [ N_SLAVES-1:0][UW+DW-1:0] cores_r_rdata;
  // slave side
  logic [N_MASTERS-1:0]            mems_req;
  logic [N_MASTERS-1:0][  AWM-1:0] mems_add;
  logic [N_MASTERS-1:0]            mems_wen;
  logic [N_MASTERS-1:0][UW+DW-1:0] mems_wdata;
  logic [N_MASTERS-1:0][DW/BW-1:0] mems_be;
  //  logic [N_MASTERS-1:0][   IW-1:0] mems_ID;
  logic [N_MASTERS-1:0]            mems_gnt;
  logic [N_MASTERS-1:0][UW+DW-1:0] mems_r_rdata;
  logic [N_MASTERS-1:0]            mems_r_valid;
  //logic [N_MASTERS-1:0][   IW-1:0] mems_r_ID;

  // interface unrolling
  generate
    for (genvar i = 0; i < N_SLAVES; i++) begin : cores_unrolling
      //request
      assign cores_req[i]         = s_cores[i].req.req;
      assign cores_wen[i]         = ~s_cores[i].req.we;
      assign cores_be[i]          = s_cores[i].req.be;
      assign cores_add[i]         = s_cores[i].req.addr;
      assign cores_wdata[i]       = s_cores[i].req.data;
      //response
      assign s_cores[i].rsp.gnt   = cores_gnt[i];
      assign s_cores[i].rsp.valid = cores_r_valid[i];
      assign s_cores[i].rsp.err   = '0;
      assign s_cores[i].rsp.data  = cores_r_rdata[i];
    end  // cores_unrolling

    for (genvar i = 0; i < N_MASTERS; i++) begin : mems_unrolling
      assign m_mems[i].req.req  = mems_req[i];
      assign m_mems[i].req.we   = ~mems_wen[i];
      assign m_mems[i].req.be   = mems_be[i];
      assign m_mems[i].req.addr = mems_add[i];
      assign m_mems[i].req.data = mems_wdata[i];
      //response
      assign mems_gnt[i]        = m_mems[i].rsp.gnt;
      assign mems_r_valid[i]    = m_mems[i].rsp.valid;
      assign mems_r_rdata[i]    = m_mems[i].rsp.data;


    end  // mems_unrolling
  endgenerate

  // uses XBAR_TCDM from cluster_interconnect
  tcdm_interconnect #(
      .NumIn       (N_CH0 + N_CH1),
      .NumOut      (N_MASTERS),
      .AddrWidth   (AWC),
      .DataWidth   (DW + UW),
      .ByteOffWidth($clog2(DW - 1) - 3),         // determine byte offset from real data width
      .AddrMemWidth(AWM),
      .WriteRespOn (1),
      .RespLat     (1),
      .BeWidth     (DW / BW),
      .Topology    (tcdm_interconnect_pkg::LIC)
  ) i_tcdm_interconnect (
      .clk_i,
      .rst_ni,

      .req_i  (cores_req),
      .add_i  (cores_add),
      .wen_i  (cores_wen),
      .wdata_i(cores_wdata),
      .be_i   (cores_be),
      .gnt_o  (cores_gnt),
      .vld_o  (cores_r_valid),
      .rdata_o(cores_r_rdata),

      .req_o  (mems_req),
      .gnt_i  (mems_gnt),
      .add_o  (mems_add),
      .wen_o  (mems_wen),
      .wdata_o(mems_wdata),
      .be_o   (mems_be),
      .rdata_i(mems_r_rdata)
  );

endmodule  // isolde_log_interconnect
