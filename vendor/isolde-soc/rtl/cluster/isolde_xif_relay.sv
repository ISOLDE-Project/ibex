module isolde_xif_relay #(
    parameter int unsigned N_TILES = 2,
    parameter int unsigned NC      = 1
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

  localparam int unsigned ID_WIDTH = $clog2(N_TILES);

  // Tile selector from XIF request
  logic [ID_WIDTH-1:0] tile_idx;

  assign tile_idx = cpu_xif_issue.issue_req.hwe_id[ID_WIDTH-1:0];

  // --------------------------------------------------
  // Events
  // --------------------------------------------------
  always_comb begin
    core_evt_o = '0;

    case (tile_idx)
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

      assign tile_xif_issue[i].issue_valid = (tile_idx == i) ? cpu_xif_issue.issue_valid : 1'b0;

      assign tile_xif_issue[i].issue_req = (tile_idx == i) ? cpu_xif_issue.issue_req : '0;

      assign tile_xif_result[i].result_ready = (tile_idx == i) ? cpu_xif_result.result_ready : 1'b0;

    end
  endgenerate

  // --------------------------------------------------
  // Tile -> CPU mux
  // --------------------------------------------------
  always_comb begin
    cpu_xif_issue.issue_ready  = 1'b0;
    cpu_xif_result.result_valid = 1'b0;
    cpu_xif_result.result       = '0;

    case (tile_idx)

      0: begin
        cpu_xif_issue.issue_ready  = tile_xif_issue[0].issue_ready;
        cpu_xif_result.result_valid = tile_xif_result[0].result_valid;
        cpu_xif_result.result       = tile_xif_result[0].result;
      end

      1:
      if (N_TILES > 1) begin
        cpu_xif_issue.issue_ready  = tile_xif_issue[1].issue_ready;
        cpu_xif_result.result_valid = tile_xif_result[1].result_valid;
        cpu_xif_result.result       = tile_xif_result[1].result;
      end

      default: begin
        cpu_xif_issue.issue_ready  = 1'b0;
        cpu_xif_result.result_valid = 1'b0;
        cpu_xif_result.result       = '0;
      end

    endcase
  end

endmodule
