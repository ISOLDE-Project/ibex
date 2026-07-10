// Copyright 2026 AUMOVIO
// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
//

module isolde_cohen_top
  import cohen_pkg::*;
#(
    parameter int unsigned ID_WIDTH = 8,
    parameter int unsigned N_CORES = 8,
    // TCDM port dimension (in bits)
    parameter int unsigned DW = DATA_W,
    parameter int unsigned AddrWidth = 32,
    // Number of PEs within a row
    parameter int unsigned Height = ARRAY_HEIGHT,
    // Number of parallel rows
    parameter int unsigned Width = ARRAY_WIDTH
    // Number of bits for the given format
) (
    input  logic                    clk_i,
    input  logic                    rst_ni,
    input  logic                    test_mode_i,
    input  logic                    fetch_enable_i,
    // evnets
    output logic [N_CORES-1:0][1:0] evt_o,

    hci_core_intf.master             m_hci_core,
    isolde_cv_x_if.coproc_issue      xif_issue_if_i,
    isolde_cv_x_if.coproc_result     xif_result_if_o,
    isolde_cv_x_if.coproc_compressed xif_compressed_if_i,
    isolde_cv_x_if.coproc_mem        xif_mem_if_o

);

  localparam int unsigned SysDataWidth = 32;
  localparam int unsigned SysInstWidth = 32;

  logic busy;
  logic s_clk, s_clk_en;





  always_ff @(posedge clk_i or negedge rst_ni) begin : clock_enable
    if (~rst_ni) s_clk_en <= 1'b0;
    else s_clk_en <= fetch_enable_i;
  end

  tc_clk_gating sys_clock_gating (
      .clk_i    (clk_i),
      .en_i     (s_clk_en),
      .test_en_i(test_mode_i),
      .clk_o    (s_clk)
  );


  cohen_top #(
      .ID_WIDTH    (ID_WIDTH),
      .N_CORES     (1),
      .DW          (DW),
      .X_EXT       (1'b1),
      .SysInstWidth(SysInstWidth),
      .SysDataWidth(SysDataWidth)
  ) i_redmule_top (
      .clk_i      (s_clk),
      .rst_ni     (rst_ni),
      .test_mode_i(test_mode_i),
      .evt_o      (evt_o),
      .busy_o     (busy),
      .tcdm       (m_hci_core),
      .xif_issue_if_i,
      .xif_result_if_o,
      .xif_compressed_if_i,
      .xif_mem_if_o
  );

endmodule : isolde_cohen_top
