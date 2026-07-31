module isolde_xif_relay #(
    parameter int unsigned N_TILES = 2,
    parameter int unsigned NC      = 1
) (
    // Full CPU interface
    isolde_cv_x_if cpu_xif,

    // Full tile interface array
    isolde_cv_x_if tile_xif [N_TILES],

    // Events
    input  logic [NC-1:0][1:0] tile_evt_i [N_TILES-1:0],
    output logic [NC-1:0][1:0] core_evt_o
);

  localparam int unsigned ID_WIDTH = $clog2(N_TILES);

  // Tile selector from XIF request
  logic [ID_WIDTH-1:0] tile_idx;

  assign tile_idx =
      cpu_xif.issue_req.hwe_id[ID_WIDTH-1:0];

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

      assign tile_xif[i].issue_valid =
          (tile_idx == i) ? cpu_xif.issue_valid : 1'b0;

      assign tile_xif[i].issue_req =
          (tile_idx == i) ? cpu_xif.issue_req : '0;

      assign tile_xif[i].result_ready =
          (tile_idx == i) ? cpu_xif.result_ready : 1'b0;

    end
  endgenerate

  // --------------------------------------------------
  // Tile -> CPU mux
  // --------------------------------------------------
  always_comb begin
    cpu_xif.issue_ready  = 1'b0;
    cpu_xif.result_valid = 1'b0;
    cpu_xif.result       = '0;

    case (tile_idx)

      0: begin
        cpu_xif.issue_ready  = tile_xif[0].issue_ready;
        cpu_xif.result_valid = tile_xif[0].result_valid;
        cpu_xif.result       = tile_xif[0].result;
      end

      1: if (N_TILES > 1) begin
        cpu_xif.issue_ready  = tile_xif[1].issue_ready;
        cpu_xif.result_valid = tile_xif[1].result_valid;
        cpu_xif.result       = tile_xif[1].result;
      end

      default: begin
        cpu_xif.issue_ready  = 1'b0;
        cpu_xif.result_valid = 1'b0;
        cpu_xif.result       = '0;
      end

    endcase
  end

endmodule