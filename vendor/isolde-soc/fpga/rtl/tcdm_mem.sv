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
    parameter MEMORY_SIZE = 512,  // number of 32-bit words
    parameter MEMORY_PRIMITIVE = "block"  // "block", "ultra", "distributed"
) (
    input logic                clk_i,
    input logic                rst_ni,
          isolde_tcdm_if.slave tcdm_slave_i
);

  // ============================================================
  // Local signals
  // ============================================================

  localparam ADDR_WIDTH = $clog2(MEMORY_SIZE);
  logic [ADDR_WIDTH-1:0] index;

  logic [31:0] mem_dout;
  logic        rsp_valid_q;

  assign tcdm_slave_i.rsp.err = 1'b0;  // No error generation
  // ============================================================
  // Address calculation (word aligned)
  // ============================================================
  assign index = tcdm_slave_i.req.addr[ADDR_WIDTH+1:2];  // word aligned
  // ============================================================
  // Grant logic 
  // ============================================================
  assign tcdm_slave_i.rsp.gnt = rst_ni && tcdm_slave_i.req.req;
  // ============================================================
  assign tcdm_slave_i.rsp.data = mem_dout;
  assign tcdm_slave_i.rsp.valid = rsp_valid_q;

  // XPM Single-Port RAM (SPRAM) : 32-bit wide with byte enables
  // ============================================================
  xpm_memory_spram #(
      .ADDR_WIDTH_A(ADDR_WIDTH),
      .BYTE_WRITE_WIDTH_A(8),  //8-bit byte-wide writes
      .MEMORY_SIZE(MEMORY_SIZE * 32),  // total bits
      .MEMORY_PRIMITIVE(MEMORY_PRIMITIVE),
      .READ_DATA_WIDTH_A(32),
      .READ_LATENCY_A(1), //Read data output to port douta takes this number of clka cycles.
      .WRITE_DATA_WIDTH_A(32),
      .WRITE_MODE_A("write_first")  // "read_first", "write_first", "no_change"
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
  // Transaction handler
  // ============================================================
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      rsp_valid_q <= 1'b0;

    end else begin

      rsp_valid_q <= tcdm_slave_i.rsp.gnt;

    end
  end

endmodule

module tcdm_mem_wrapper #(
    parameter MEMORY_SIZE = 512,  // number of 32-bit words
    parameter MEMORY_PRIMITIVE = "block"  // "block", "ultra", "distributed"
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
      .MEMORY_SIZE(MEMORY_SIZE),
      .MEMORY_PRIMITIVE(MEMORY_PRIMITIVE)
  ) dut (
      .clk_i(clk_i),
      .rst_ni(rst_ni),
      .tcdm_slave_i(tcdm_intf.slave)  // connect the modport
  );

endmodule
