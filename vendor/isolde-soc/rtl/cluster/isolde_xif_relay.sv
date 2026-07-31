module isolde_xif_relay #(
    parameter int unsigned N_TILES = 2,
    parameter int unsigned TILE_IDX = 0,
    parameter int unsigned NC = 1
)(
    // Full CPU interface
    isolde_cv_x_if cpu_xif,

    // Full tile interface array
    isolde_cv_x_if tile_xif [N_TILES],

    // Events
    input  logic [N_TILES-1:0][NC-1:0][1:0] tile_evt_i,
    output logic [NC-1:0][1:0]              core_evt_o
);

  // Events
  assign core_evt_o = tile_evt_i[TILE_IDX];

  // --------------------------------------------------
  // Issue channel: CPU -> selected tile
  // --------------------------------------------------
  assign tile_xif[TILE_IDX].issue_valid = cpu_xif.issue_valid;
  assign tile_xif[TILE_IDX].issue_req   = cpu_xif.issue_req;
  assign cpu_xif.issue_ready            = tile_xif[TILE_IDX].issue_ready;

  // --------------------------------------------------
  // Result channel: selected tile -> CPU
  // --------------------------------------------------
  assign cpu_xif.result_valid           = tile_xif[TILE_IDX].result_valid;
  assign cpu_xif.result                 = tile_xif[TILE_IDX].result;
  assign tile_xif[TILE_IDX].result_ready = cpu_xif.result_ready;

  // --------------------------------------------------
  // Temporary: ignore memory channel
  // --------------------------------------------------
  assign tile_xif[TILE_IDX].mem_ready = 1'b1;

endmodule