// Copyleft 2024 ISOLDE

module isolde_tile_router
//import isolde_tcdm_pkg::*;
#(
    parameter int START_ADDR = 32'h00100000,  // Start address for valid address range
    parameter int END_ADDR = 32'h00108000,  // End address for valid address range
    parameter int unsigned N_TILES = 1,
    parameter int unsigned IDXWidth = (N_TILES > 1) ? $clog2(N_TILES) : 1

) (
    input logic clk_i,
    input logic rst_ni,
    isolde_cv_x_if.monitor_issue issue_if,
    // Interface for CPU requests
    input isolde_tcdm_pkg::req_t req_i,
    output isolde_tcdm_pkg::rsp_t rsp_o,
    output isolde_tcdm_pkg::req_t req_o[N_TILES],
    input isolde_tcdm_pkg::rsp_t rsp_i[N_TILES]

);

  typedef logic [IDXWidth-1:0] idx_t;
  isolde_tcdm_if tcdm_slave_tmp ();  // Interface for memory response

  isolde_addr_shim #(
      .START_ADDR(START_ADDR),
      .END_ADDR  (END_ADDR)
  ) i_addr_shim (
      .req_i(req_i),
      .rsp_o(rsp_o),
      .tcdm_master_o(tcdm_slave_tmp)
  );


  // Response valid is OR of all submodule valids
  logic [N_TILES-1:0] rsp_valid_vec;
  logic [N_TILES-1:0] rsp_gnt_vec;


  generate
    for (genvar i = 0; i < N_TILES; i++) begin
      assign rsp_valid_vec[i] = rsp_i[i].valid;
      assign rsp_gnt_vec[i]   = rsp_i[i].gnt;
    end
  endgenerate

  logic fifo_full, fifo_empty;
  logic push_id_fifo, pop_id_fifo;
  idx_t selected_idx, req_idx, rsp_idx;


  assign push_id_fifo = |rsp_gnt_vec;
  assign pop_id_fifo  = |rsp_valid_vec;

  assign selected_idx = idx_t'(issue_if.hwe_id);
  ;



  // Remember selected master for correct forwarding of read data/acknowledge.
  fifo_v3 #(
      .DATA_WIDTH(IDXWidth),
      .DEPTH(4)
  ) i_id_fifo (
      .clk_i,
      .rst_ni,
      .flush_i(1'b0),
      .testmode_i(1'b0),
      .full_o(fifo_full),
      .empty_o(fifo_empty),
      .usage_o(),
      // Onehot mask.
      .data_i(selected_idx),
      .push_i(push_id_fifo),
      .data_o(rsp_idx),
      .pop_i(pop_id_fifo)
  );


  assign req_idx = selected_idx;


  always_comb begin : bind_req
    for (int i = 0; i < N_TILES; i++) begin
      req_o[i] = '0;
      if (req_idx == idx_t'(i)) begin
        req_o[i] = tcdm_slave_tmp.req;
      end
    end
    //end
  end


  always_comb begin : bind_rsp

    tcdm_slave_tmp.rsp.gnt   = |rsp_gnt_vec;
    tcdm_slave_tmp.rsp.valid = |rsp_valid_vec;
    tcdm_slave_tmp.rsp.err   = '0;
    tcdm_slave_tmp.rsp.data  = '0;
    for (int i = 0; i < N_TILES; i++) begin
      if (rsp_idx == idx_t'(i)) begin
        tcdm_slave_tmp.rsp.data = rsp_i[i].data;
      end
    end
  end




  // Compile-time assertion of N_TILES > 0
  // Excluded from synthesis 
`ifndef SYNTHESIS
  initial begin
    assert (N_TILES > 0)
    else $fatal("[isolde_demux_tcdm] ERROR: N_TILES parameter must be > 0 (got %0d)", N_TILES);
  end

  always_ff @(posedge clk_i) begin
    assert (!(push_id_fifo && fifo_full))
    else $fatal("ID FIFO overflow");
    assert (!(pop_id_fifo && fifo_empty))
    else $fatal("ID FIFO underflow");
  end
`endif
endmodule

