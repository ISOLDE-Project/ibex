module isolde_uart_top_tb (
    input logic clk_i,
    input logic rst_ni,
    input logic fetch_enable_i

);

  isolde_tcdm_pkg::req_t core_req;
  isolde_tcdm_pkg::rsp_t core_rsp;

logic uart_tx;
    logic        data_tx_req;
    logic        data_tx_gnt;
    logic [31:0] data_tx;
    logic        data_tx_valid;
    logic        data_tx_ready;


assign data_tx = core_req.data;
assign data_tx_valid = core_req.req;


  task automatic uart_req( input logic [31:0] data,
                          input logic write_enable);
    begin
      core_req.req  = 1;
      core_req.we   = write_enable;
      core_req.be   = write_enable ? 4'b1111 : 4'b0000;
      core_req.addr = 32'h0;
      core_req.data = data;
      @(posedge clk_i);
      core_req.req = 0;
      core_req.we  = 0;
      core_req.be  = 4'b0000;
      //wait (cores_rsp.valid);
    end
  endtask

  // Instantiate the shim with START_ADDR and END_ADDR parameters
  isolde_uart_top_tb #(
      .CLOCK_FREQ(115200)
  ) dut (
      .sys_clk_i(clk_i),
      .rstn_i (rst_ni),
    .uart_tx_o(uart_tx),
    .data_tx_req_o(data_tx_req),
    .data_tx_gnt_i(data_tx_gnt),
    .data_tx_i(data_tx),
    .data_tx_valid_i(data_tx_valid),
    .data_tx_ready_o(data_tx_ready)
  );



    initial begin
      $display("Starting Test...");
    

    // Wait for fetch_enable_i  
    wait (fetch_enable_i);
    @(posedge clk_i);
    //read preloaded values
    uart_req(32'hDA_CA_BA_AA,1'b1);


    //   // === End test ===
    @(posedge clk_i);
    $display("[Time %0t] ✅ Test complete", $time);
    $finish;
  end
endmodule
