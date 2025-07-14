// Copyleft 2024 ISOLDE

module isolde_router #(
    parameter int N_RULES = -1
  
) (
    input logic clk_i,
    input logic rst_ni,
    input isolde_tcdm_pkg::addr_range_t  addr_range_i[N_RULES-1:0],
    input  isolde_tcdm_if.slave  tcdm_slave_i,
    output isolde_tcdm_if.master tcdm_master_o[N_RULES-1:0] 
);

  localparam int unsigned IDXWidth = $clog2(N_RULES+1); 
  typedef logic [IDXWidth-1:0] rule_idx_t;


  isolde_tcdm_pkg::tb_rule_t addr_map [N_RULES-1:0];

always_comb begin
  for (int i=0; i < N_RULES; i++) begin
    addr_map[i].idx        = rule_idx_t'(i+1);
    addr_map[i].start_addr = addr_range_i[i].start_addr;
    addr_map[i].end_addr   = addr_range_i[i].end_addr;
  end
end


  localparam rule_idx_t INVALID = rule_idx_t'(0);
  localparam rule_idx_t LAST_IDX = rule_idx_t'(N_RULES);
  localparam int unsigned NoIndices = LAST_IDX;


logic fifo_full, fifo_empty;
  logic push_id_fifo, pop_id_fifo;
  rule_idx_t selected_idx, rsp_idx;


  assign push_id_fifo = ~fifo_full & tcdm_slave_i.rsp.gnt;
  assign pop_id_fifo  = ~fifo_empty & tcdm_slave_i.rsp.valid;

  always_ff @(posedge clk_i, negedge rst_ni)
    if (!rst_ni) begin
      rsp_idx <= INVALID;
    end


  addr_decode #(
      .NoIndices(NoIndices),    // number indices in rules
      .NoRules  (N_RULES),      // total number of rules
      .addr_t   (isolde_tcdm_pkg::rule_addr_t),  // address type
      .rule_t   (isolde_tcdm_pkg::tb_rule_t)     // has to be overridden, see above!
  ) i_addr_decode_dut (
      .addr_i(tcdm_slave_i.req.addr),  // address to decode
      .addr_map_i(addr_map),  // address map: rule with the highest position wins
      .idx_o(selected_idx),  // decoded index
      .dec_valid_o(),  // decode is valid
      .dec_error_o(),  // decode is not valid
      // Default index mapping enable
      .en_default_idx_i(1'b1),  // enable default port mapping
      .default_idx_i(INVALID)  // default port index
  );





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



  always_comb begin
    for (int i = 0; i < N_RULES; i++) begin
        tcdm_master_o[i].req = '0;
    end
    if (selected_idx != INVALID ) begin
      tcdm_master_o[selected_idx-1].req = tcdm_slave_i.req;
    end
  end


  always_comb begin
    tcdm_slave_i.rsp.gnt = '0;
    if (tcdm_slave_i.req.req) begin
      if (selected_idx != INVALID) begin
        tcdm_slave_i.rsp.gnt = tcdm_master_o[selected_idx-1].rsp.gnt;
      end
    end
  end

 always_comb begin
    if(rsp_idx != INVALID ) begin
      tcdm_slave_i.rsp.data = tcdm_master_o[rsp_idx-1].rsp.data;
    end
  end

    


     // Response valid is OR of all submodule valids
logic [N_RULES-1:0] rsp_valid_vec;
generate
  for (genvar i=0; i < N_RULES; i++) begin
    assign rsp_valid_vec[i] = tcdm_master_o[i].rsp.valid;
  end
endgenerate
assign tcdm_slave_i.valid = |rsp_valid_vec;

 



  // Compile-time assertion of N_RULES > 0
  // Excluded from synthesis 
  `ifndef SYNTHESIS
  initial begin
    assert (N_RULES > 0)
      else $fatal("[isolde_demux_tcdm] ERROR: N_RULES parameter must be > 0 (got %0d)", N_RULES);
  end
  `endif
  endmodule

