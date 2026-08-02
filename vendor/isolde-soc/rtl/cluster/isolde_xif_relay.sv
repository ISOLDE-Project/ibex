module isolde_xif_relay #(
    parameter int unsigned N_TILES  = 2,
    parameter int unsigned NC       = 1,
    parameter int unsigned ID_WIDTH = (N_TILES > 1) ? $clog2(N_TILES) : 1

) (
    input logic clk_i,
    input logic rst_ni,
    //cpu interface
    isolde_cv_x_if.coproc_issue cpu_xif_issue,
    isolde_cv_x_if.coproc_result cpu_xif_result,


    // tile interfaces
    isolde_cv_x_if.cpu_issue  tile_xif_issue [N_TILES],
    isolde_cv_x_if.cpu_result tile_xif_result[N_TILES],

    // Events
    input  logic [NC-1:0][1:0] tile_evt_i[N_TILES-1:0],
    output logic [NC-1:0][1:0] core_evt_o
);

  

  // Tile selector from XIF request
  typedef logic [ID_WIDTH-1:0] idx_t;


  // Response valid is OR of all submodule valids
  logic [ N_TILES-1:0] issue_ready_vec;
  logic [ N_TILES-1:0] result_valid_vec;

  generate
    for (genvar i = 0; i < N_TILES; i++) begin
      assign issue_ready_vec[i]  = tile_xif_issue[i].issue_ready;
      assign result_valid_vec[i] = tile_xif_result[i].result_valid;
    end
  endgenerate

  logic fifo_full, fifo_empty;
  logic push_id_fifo, pop_id_fifo;
  idx_t selected_idx, req_idx, rsp_idx;


  assign push_id_fifo = |issue_ready_vec;
  assign pop_id_fifo = |result_valid_vec;

  assign req_idx = idx_t'(cpu_xif_issue.issue_req.hwe_id[ID_WIDTH-1:0]);



  // Remember selected master for correct forwarding of read data/acknowledge.
  fifo_v3 #(
      .DATA_WIDTH(ID_WIDTH),
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
      .data_i(req_idx),
      .push_i(push_id_fifo),
      .data_o(rsp_idx),
      .pop_i(pop_id_fifo)
  );





  // --------------------------------------------------
  // Events
  // --------------------------------------------------
  always_comb begin
    core_evt_o = '0;

    case (rsp_idx)
      0: core_evt_o = tile_evt_i[0];
      1: if (N_TILES > 1) core_evt_o = tile_evt_i[1];
      default: core_evt_o = '0;
    endcase
  end

  // --------------------------------------------------
  // CPU -> tile dispatch
  // --------------------------------------------------
  genvar i;
  generate
    for (i = 0; i < N_TILES; i++) begin : g_tile

      assign tile_xif_issue[i].issue_valid = (req_idx == i) ? cpu_xif_issue.issue_valid : 1'b0;

      assign tile_xif_issue[i].issue_req = (req_idx == i) ? cpu_xif_issue.issue_req : '0;

      assign tile_xif_result[i].result_ready = (req_idx == i) ? cpu_xif_result.result_ready : 1'b0;

    end
  endgenerate

  // --------------------------------------------------
  // Tile -> CPU mux
  // --------------------------------------------------
  always_comb begin
    cpu_xif_issue.issue_ready   = 1'b0;
    cpu_xif_result.result_valid = 1'b0;
    cpu_xif_result.result       = '0;

    case (rsp_idx)

      0: begin
        cpu_xif_issue.issue_ready   = tile_xif_issue[0].issue_ready;
        cpu_xif_result.result_valid = tile_xif_result[0].result_valid;
        cpu_xif_result.result       = tile_xif_result[0].result;
      end

      1:
      if (N_TILES > 1) begin
        cpu_xif_issue.issue_ready   = tile_xif_issue[1].issue_ready;
        cpu_xif_result.result_valid = tile_xif_result[1].result_valid;
        cpu_xif_result.result       = tile_xif_result[1].result;
      end

      default: begin
        cpu_xif_issue.issue_ready   = 1'b0;
        cpu_xif_result.result_valid = 1'b0;
        cpu_xif_result.result       = '0;
      end

    endcase
  end

endmodule
