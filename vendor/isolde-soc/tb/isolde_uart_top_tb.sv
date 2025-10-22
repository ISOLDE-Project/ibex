module isolde_uart_top_tb (
    input logic clk_i,
    input logic rst_ni,
    input logic fetch_enable_i

);

  isolde_tcdm_pkg::req_t core_req;
  isolde_tcdm_pkg::rsp_t core_rsp;

  logic uart_tx;



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
      //wait (cores_rsp.valid);
    end
  endtask

  // Instantiate the shim with START_ADDR and END_ADDR parameters
  isolde_uart_top #(
      .CLOCK_FREQ(115200)
  ) dut (
      .sys_clk_i(clk_i),
      .rstn_i(rst_ni),
      .uart_tx_o(uart_tx),
      .uart_req_i(core_req),
      .uart_rsp_o(core_rsp)
  );



  initial begin
    $display("Starting Test...");


    // Wait for fetch_enable_i  
    wait (fetch_enable_i);
    @(posedge clk_i);
    //read preloaded values
    uart_req(32'hDA_CA_BA_AA, 1'b1);
    uart_req(32'hDE_AD_BE_EF, 1'b1);
    uart_req(32'hFE_ED_FA_CE, 1'b1);
    



    //   // === End test ===
    repeat (200) @(posedge clk_i);
    $display("[Time %0t] ✅ Test complete", $time);
    $finish;
  end
endmodule
