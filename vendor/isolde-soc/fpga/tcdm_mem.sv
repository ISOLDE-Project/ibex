// Synthesizable memory model for Vivado (ZCU104)
// Clean 32-bit wide XPM SPRAM with byte enables

module tcdm_mem #(
    parameter BASE_ADDR    = 0,
    parameter MEMORY_SIZE  = 1024,   // number of 32-bit words
    parameter DELAY_CYCLES = 0
) (
    input logic                clk_i,
    input logic                rst_ni,
          isolde_tcdm_if.slave tcdm_slave_i
);

  // ============================================================
  // Local signals
  // ============================================================
  logic [31:0] delay_counter;
  logic [31:0] index;

  int cnt_wr = 0;
  int cnt_rd = 0;

  localparam ADDR_WIDTH = $clog2(MEMORY_SIZE);

  logic [31:0] mem_dout;

  // ============================================================
  // XPM Single-Port RAM (SPRAM) : 32-bit wide with byte enables
  // ============================================================
  xpm_memory_spram #(
      .ADDR_WIDTH_A(ADDR_WIDTH),
      .MEMORY_SIZE(MEMORY_SIZE * 32),  // total bits
      .MEMORY_PRIMITIVE("block"),  // "block" for BRAM, "ultra" for URAM, "distributed" for LUTRAM
      .READ_DATA_WIDTH_A(32),
      .WRITE_DATA_WIDTH_A(32),
      .WRITE_MODE_A("read_first"),  // "read_first", "write_first", "no_change"
      .CLOCKING_MODE("common_clock")
  ) xpm_mem_inst (
      // -----------------------------
      // WRITE into XPM memory
      // -----------------------------
      .clka (clk_i),
      .ena  (1'b1),
      .wea  (tcdm_slave_i.req.we ? tcdm_slave_i.req.be : 4'b0000),  // <--- WRITE ENABLES
      .addra(index[ADDR_WIDTH-1:0]),                                // <--- ADDRESS
      .dina (tcdm_slave_i.req.data),                                // <--- WRITE DATA

      // -----------------------------
      // READ from XPM memory
      // -----------------------------
      .douta(mem_dout),  // <--- READ DATA OUT

      // Reset & optional signals
      .rsta   (~rst_ni),
      .regcea (1'b1),
      .sleep  (1'b0),
      .injectsbiterra(1'b0),
      .injectdbiterra(1'b0),
      .sbiterra(),
      .dbiterra()
  );

  // ============================================================
  // Address calculation (word aligned)
  // ============================================================
  always_comb begin
    if (rst_ni && tcdm_slave_i.req.req) tcdm_slave_i.rsp.gnt = (delay_counter == 0) ? 1'b1 : 1'b0;
    else tcdm_slave_i.rsp.gnt = 1'b0;

    index = (tcdm_slave_i.req.addr - BASE_ADDR) >> 2;
  end

  // ============================================================
  // Transaction handler
  // ============================================================
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      tcdm_slave_i.rsp.data  <= '0;
      tcdm_slave_i.rsp.valid <= 1'b0;
      delay_counter          <= DELAY_CYCLES;
    end else begin
      if (tcdm_slave_i.rsp.gnt) begin
        tcdm_slave_i.rsp.gnt <= 1'b0;
        delay_counter <= DELAY_CYCLES;

        if (tcdm_slave_i.req.we) begin
          // -----------------------------
          // WRITE: data goes into XPM
          // -----------------------------
          cnt_wr <= cnt_wr + 1;
          tcdm_slave_i.rsp.data <= tcdm_slave_i.req.data;
          tcdm_slave_i.rsp.valid <= 1'b1;
        end else begin
          // -----------------------------
          // READ: return XPM data
          // -----------------------------
          cnt_rd <= cnt_rd + 1;
          tcdm_slave_i.rsp.data <= mem_dout;  // <--- USE READ DATA
          tcdm_slave_i.rsp.valid <= 1'b1;
        end

      end else begin
        delay_counter <= tcdm_slave_i.req.req ? delay_counter - 1 : DELAY_CYCLES;
        tcdm_slave_i.rsp.data <= '0;
        tcdm_slave_i.rsp.valid <= 1'b0;
      end
    end
  end

endmodule
