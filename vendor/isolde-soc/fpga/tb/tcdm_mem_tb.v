`timescale 1ns / 1ps

module tcdm_mem_tb;

  // ============================================================
  // Parameters
  // ============================================================
  localparam BASE_ADDR    = 32'h0000_0000;
  localparam MEMORY_SIZE  = 1024;   // 32-bit words
  localparam DELAY_CYCLES = 0;

  localparam CORE_DW  = 32;
  localparam CORE_AW  = 32;
  localparam CORE_BEW = 4;

  // ============================================================
  // Clock / Reset
  // ============================================================
  reg clk;
  reg rst_n;

  initial clk = 0;
  always #5 clk = ~clk;  // 100 MHz

  initial begin
    rst_n = 0;
    #100;
    rst_n = 1;
  end

  // ============================================================
  // TCDM Request / Response signals
  // ============================================================
  reg                req_req;
  reg                req_we;
  reg  [CORE_BEW-1:0] req_be;
  reg  [CORE_AW-1:0] req_addr;
  reg  [CORE_DW-1:0] req_data;

  wire               rsp_gnt;
  wire               rsp_valid;
  wire               rsp_err;
  wire [CORE_DW-1:0] rsp_data;

  // ============================================================
  // DUT: Wrapper
  // ============================================================
  tcdm_mem_wrapper #(
    .BASE_ADDR(BASE_ADDR),
    .MEMORY_SIZE(MEMORY_SIZE),
    .DELAY_CYCLES(DELAY_CYCLES)
  ) dut (
    .clk_i(clk),
    .rst_ni(rst_n),
    .req_req(req_req),
    .req_we(req_we),
    .req_be(req_be),
    .req_addr(req_addr),
    .req_data(req_data),
    .gnt(rsp_gnt),
    .valid(rsp_valid),
    .err(rsp_err),
    .rsp_data(rsp_data)
  );

  // ============================================================
  // Test Sequence
  // ============================================================
  initial begin
    // Initialize signals
    req_req  = 0;
    req_we   = 0;
    req_be   = 4'b0000;
    req_addr = 0;
    req_data = 0;

    // Wait for reset deassertion
    @(posedge rst_n);

    // -------------------------
    // Write transaction
    // -------------------------
    @(posedge clk);
    req_req  = 1;
    req_we   = 1;
    req_be   = 4'b1111;           // full word write
    req_addr = 32'h0000_0000;
    req_data = 32'hDEADBEEF;

    @(posedge clk);
    req_req  = 0;
    req_we   = 0;

    // Wait for grant
    wait (rsp_gnt == 1);

    // -------------------------
    // Read transaction
    // -------------------------
    repeat (2) @(posedge clk); // small gap
    req_req  = 1;
    req_we   = 0;
    req_be   = 4'b0000;
    req_addr = 32'h0000_0000;

    @(posedge clk);
    req_req = 0;

    // Wait for response
    wait (rsp_valid == 1);
    $display("Read Data = 0x%08h", rsp_data);

    // -------------------------
    // Finish
    // -------------------------
    repeat (5) @(posedge clk);
    $finish;
  end

endmodule
