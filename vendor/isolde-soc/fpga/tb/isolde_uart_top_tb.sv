`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 10/27/2025 04:43:49 PM
// Design Name: 
// Module Name: isolde_uart_top_tb
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module isolde_uart_top_tb;

  // Internal signals (used to drive DUT)
  logic clk_i;
  logic rst_ni;
  logic fetch_enable_i;

  isolde_tcdm_pkg::req_t core_req;
  isolde_tcdm_pkg::rsp_t core_rsp;
  logic uart_tx;

  // Clock generation (100 MHz)
  initial clk_i = 0;
  always #5 clk_i = ~clk_i;

  // Reset and enable control
  initial begin
    rst_ni = 0;
    fetch_enable_i = 0;
    #100;
    rst_ni = 1;
    #50;
    fetch_enable_i = 1;
  end

  // Task for UART request
  task automatic uart_req(input logic [31:0] data, input logic write_enable);
    begin
      core_req.req  = 1;
      core_req.we   = write_enable;
      core_req.be   = write_enable ? 4'b1111 : 4'b0000;
      core_req.addr = 32'h0;
      core_req.data = data;
      @(posedge clk_i);
      wait (core_rsp.gnt);
      core_req.req = 0;
      core_req.we  = 0;
      core_req.be  = 4'b0000;
      @(posedge clk_i);
    end
  endtask

  // DUT instantiation
  isolde_uart_top #(
      .CLOCK_FREQ(115200)
  ) dut (
      .sys_clk_i(clk_i),
      .rstn_i(rst_ni),
      .uart_tx_o(uart_tx),
      .uart_req_i(core_req),
      .uart_rsp_o(core_rsp)
  );

  // Test sequence
  initial begin
    $display("Starting Test...");

    // Wait until fetch_enable_i is high
    wait (fetch_enable_i);
    @(posedge clk_i);

    // Stimulus
    uart_req(32'hDA_CA_BA_AA, 1'b1);
    uart_req(32'hDE_AD_BE_EF, 1'b1);
    uart_req(32'hFE_ED_FA_CE, 1'b1);

    // Wait for completion
    repeat (200) @(posedge clk_i);
    $display("[Time %0t] ✅ Test complete", $time);
    $finish;
  end

endmodule

