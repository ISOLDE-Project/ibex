`timescale 1ns/1ps

module tcdm_mem_tb;

  // ============================================================
  // Parameters
  // ============================================================
  localparam BASE_ADDR    = 32'h0000_0000;
  localparam MEMORY_SIZE  = 1024;   // 32-bit words
  localparam DELAY_CYCLES = 0;

  // ============================================================
  // Clock / Reset
  // ============================================================
  logic clk;
  logic rst_n;

  initial clk = 0;
  always #5 clk = ~clk;  // 100 MHz clock

  initial begin
    rst_n = 0;
    #100;
    rst_n = 1;
  end

  // ============================================================
  // Dummy TCDM Interface Declaration
  // ============================================================
  // For this testbench, we "model" the isolde_tcdm_if as simple signals
  typedef struct packed {
    logic        req;     // request valid
    logic        we;      // write enable
    logic [3:0]  be;      // byte enables
    logic [31:0] addr;    // address
    logic [31:0] data;    // write data
  } tcdm_req_t;

  typedef struct packed {
    logic        gnt;     // grant
    logic        valid;   // read data valid
    logic [31:0] data;    // read data
  } tcdm_rsp_t;

  tcdm_req_t tcdm_req;
  tcdm_rsp_t tcdm_rsp;

  // ============================================================
  // DUT: Memory instance
  // ============================================================
  tb_tcdm_mem #(
    .BASE_ADDR   (BASE_ADDR),
    .MEMORY_SIZE (MEMORY_SIZE),
    .DELAY_CYCLES(DELAY_CYCLES)
  ) dut (
    .clk_i      (clk),
    .rst_ni     (rst_n),
    .tcdm_slave_i.req (tcdm_req),
    .tcdm_slave_i.rsp (tcdm_rsp)
  );

  // ============================================================
  // Test Sequence
  // ============================================================
  initial begin
    // Initialize interface
    tcdm_req = '{req:0, we:0, be:4'h0, addr:32'h0, data:32'h0};

    // Wait for reset
    @(posedge rst_n);

    // -------------------------
    // Write transaction
    // -------------------------
    @(posedge clk);
    tcdm_req.req  = 1;
    tcdm_req.we   = 1;
    tcdm_req.be   = 4'b1111;           // full word write
    tcdm_req.addr = 32'h0000_0000;
    tcdm_req.data = 32'hDEADBEEF;

    @(posedge clk);
    tcdm_req.req  = 0;
    tcdm_req.we   = 0;

    // Wait for grant
    wait (tcdm_rsp.gnt == 1);

    // -------------------------
    // Read transaction
    // -------------------------
    repeat (2) @(posedge clk); // small gap
    tcdm_req.req  = 1;
    tcdm_req.we   = 0;
    tcdm_req.be   = 4'b0000;
    tcdm_req.addr = 32'h0000_0000;

    @(posedge clk);
    tcdm_req.req  = 0;

    // Wait for response
    wait (tcdm_rsp.valid == 1);
    $display("Read Data = 0x%08h", tcdm_rsp.data);

    // -------------------------
    // Finish
    // -------------------------
    repeat (5) @(posedge clk);
    $finish;
  end

endmodule
