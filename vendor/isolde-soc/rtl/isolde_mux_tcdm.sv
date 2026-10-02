// Copyleft 2025 ISOLDE

module isolde_mux_tcdm (
    input  logic                  clk_i,
    input  logic                  rst_ni,

    // Slave interfaces (LSUs)
    input  isolde_tcdm_pkg::req_t req_1_i,
    output isolde_tcdm_pkg::rsp_t rsp_1_o,

    input  isolde_tcdm_pkg::req_t req_2_i,
    output isolde_tcdm_pkg::rsp_t rsp_2_o,

    // Master TCDM interface
    isolde_tcdm_if.master         tcdm_master_o
);

  // 1-bit owner: 1 = LSU2, 0 = LSU1
  logic owner_d, owner_q;

  //-----------------------------
  // Request arbitration (combinational)
  //-----------------------------
  always_comb begin
    if (req_2_i.req)
      owner_d = 1'b1;
    else if (req_1_i.req)
      owner_d = 1'b0;
    else
      owner_d = owner_q; // no request, maintain previous
  end

  // Forward selected request to TCDM
  assign tcdm_master_o.req = owner_d ? req_2_i : req_1_i;

  //-----------------------------
  // Capture which requester was granted (one outstanding request!)
  //-----------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)
      owner_q <= 1'b0;
    else if (tcdm_master_o.rsp.gnt)
      owner_q <= owner_d;   // Store requester associated with the transaction
  end

  //-----------------------------
  // Grant routing
  //-----------------------------
  assign rsp_1_o.gnt = (owner_d == 1'b0) ? tcdm_master_o.rsp.gnt : 1'b0;
  assign rsp_2_o.gnt = (owner_d == 1'b1) ? tcdm_master_o.rsp.gnt : 1'b0;

  //-----------------------------
  // Response routing
  //-----------------------------
  assign rsp_1_o.valid = (owner_q == 1'b0) ? tcdm_master_o.rsp.valid : 1'b0;
  assign rsp_2_o.valid = (owner_q == 1'b1) ? tcdm_master_o.rsp.valid : 1'b0;

  assign rsp_1_o.data  = tcdm_master_o.rsp.data;
  assign rsp_2_o.data  = tcdm_master_o.rsp.data;

  // err was previously left undriven, which propagates X into every master
  // fanned out through this mux
  assign rsp_1_o.err   = (owner_q == 1'b0) ? tcdm_master_o.rsp.err : 1'b0;
  assign rsp_2_o.err   = (owner_q == 1'b1) ? tcdm_master_o.rsp.err : 1'b0;

endmodule
