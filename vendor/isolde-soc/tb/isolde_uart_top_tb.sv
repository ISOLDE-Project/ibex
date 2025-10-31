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
      wait (core_rsp.valid);
    end
  endtask
  // Read task with check
  task automatic read_and_check( input logic [7:0] expected);
    logic [7:0] read_data;
    begin
      uart_req( 32'hABAD_F00D, 1'b0);  // Read request
      read_data = core_rsp.data[7:0];

      if (read_data !== expected) begin
        $error("[Time %0t] ❌ Read mismatch: expected %h, got %h", $time, 
               expected, read_data);
      end else begin
        $display("[Time %0t] ✅ Read success: value = %h", $time, read_data);
      end
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
     $display("[Time %0t] ✅ writes done!", $time);
    read_and_check(8'hCE);



    //   // === End test ===
    repeat (200) @(posedge clk_i);
    $display("[Time %0t] ✅ Test complete", $time);
    $finish;
  end
endmodule
