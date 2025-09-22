// Synthesizable memory model for Vivado (ZCU104)
// Clean 32-bit wide XPM SPRAM with byte enables
/*
Default value targets a RAMB18E2 (18 Kb Block RAM) in Xilinx FPGAs.
| **Port Width (bits)**         | **Max Depth (entries)** | **Total Bits** |
| ----------------------------- | ----------------------- | -------------- |
| 1                             | 16,384                  | 16,384         |
| 2                             | 8,192                   | 16,384         |
| 4                             | 4,096                   | 16,384         |
| 9  (*includes parity bit*)    | 2,048                   | 18,432         |
| **18** (*16 data + 2 parity*) | **1,024**               | **18,432**     |
| 36 (*32 data + 4 parity*)     | 512                     | 18,432         |

MEMORY_PRIMITIVE options:
    "auto"- Allow Vivado Synthesis to choose
    "distributed"- Distributed memory
    "block"- Block memory
    "ultra"- Ultra RAM memory
    "mixed"- Mixed memory

*/

module tcdm_mem #(
    parameter BASE_ADDR    = 0,
    parameter MEMORY_SIZE  = 512,   // number of 32-bit words
    parameter DELAY_CYCLES = 0,
    parameter MEMORY_PRIMITIVE = "block" // "block", "ultra", "distributed"
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
      .MEMORY_PRIMITIVE(MEMORY_PRIMITIVE),
      .READ_DATA_WIDTH_A(32),
      .WRITE_DATA_WIDTH_A(32),
      .WRITE_MODE_A("read_first")  // "read_first", "write_first", "no_change"
      //.CLOCKING_MODE("common_clock")
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

module tcdm_mem_wrapper #(
    parameter BASE_ADDR    = 0,
    parameter MEMORY_SIZE  = 512,   // number of 32-bit words
    parameter DELAY_CYCLES = 0,
    parameter MEMORY_PRIMITIVE = "block" // "block", "ultra", "distributed"
) (
    input clk_i,
    input rst_ni,
    input req_req,
    input req_we,
    input [3:0] req_be,
    input [31:0] req_addr,
    input [31:0] req_data,
    output gnt,
    output valid,
    output err,
    output [31:0] rsp_data
);

  // Instantiate the SV interface internally
  isolde_tcdm_if tcdm_intf ();

  // Map wrapper signals to interface using assign
  assign tcdm_intf.req.req  = req_req;
  assign tcdm_intf.req.we   = req_we;
  assign tcdm_intf.req.be   = req_be;
  assign tcdm_intf.req.addr = req_addr;
  assign tcdm_intf.req.data = req_data;

  assign gnt                = tcdm_intf.rsp.gnt;
  assign valid              = tcdm_intf.rsp.valid;
  assign err                = tcdm_intf.rsp.err;
  assign rsp_data           = tcdm_intf.rsp.data;

  // Instantiate the original SV DUT
  tcdm_mem #(
      .BASE_ADDR(BASE_ADDR),
      .MEMORY_SIZE(MEMORY_SIZE),
      .DELAY_CYCLES(DELAY_CYCLES),
      .MEMORY_PRIMITIVE(MEMORY_PRIMITIVE)
  ) dut (
      .clk_i(clk_i),
      .rst_ni(rst_ni),
      .tcdm_slave_i(tcdm_intf.slave)  // connect the modport
  );

endmodule
