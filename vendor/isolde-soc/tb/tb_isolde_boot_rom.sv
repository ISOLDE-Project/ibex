`timescale 1ns / 1ps

module tb_isolde_boot_rom (
    input logic clk_i,
    input logic rst_ni,
    input logic fetch_enable_i

);


  // Parameters
  localparam logic [31:0] BASE_ADDR = 32'h0000_0080;

  // DUT interface signals
  isolde_tcdm_pkg::req_t dut_req;
  isolde_tcdm_pkg::rsp_t dut_rsp;


  task automatic tcdm_req(input logic [31:0] addr, input logic [31:0] data,
                          input logic write_enable);
    begin
      dut_req.req  = 1;
      dut_req.we   = write_enable;
      dut_req.be   = write_enable ? 4'b1111 : 4'b0000;
      dut_req.addr = addr;
      dut_req.data = data;
      @(posedge clk_i);
      dut_req.req = 0;
      dut_req.we  = 0;
      dut_req.be  = 4'b0000;
      //@(posedge clk_i);
      wait (dut_rsp.gnt);
      //@(posedge clk_i);
      wait (dut_rsp.valid);
    end
  endtask

  // Read task with check
  task automatic read_and_check(input logic [31:0] addr, input logic [31:0] expected);
    logic [31:0] read_data;
    begin
      tcdm_req(addr, 32'hABAD_F00D, 1'b0);  // Read request
      read_data = dut_rsp.data;

      if (read_data !== expected) begin
        $error("[Time %0t] ❌ Read mismatch at address %h: expected %h, got %h", $time, addr,
               expected, read_data);
      end else begin
        $display("[Time %0t] ✅ Read success at address %h: value = %h", $time, addr, read_data);
      end
    end
  endtask


  isolde_boot_rom #(
      .BASE_ADDR(BASE_ADDR)
  ) i_boot_rom (
      .clk_i,
      .boot_req_i(dut_req),
      .boot_rsp_o(dut_rsp)
  );


  // Input signal generation
  //https://github.com/verilator/verilator/issues/5210
  //*
  //if you need <= assignment in initial block, change the block into allways, otherways it will be treated as =, blocking assigment.
  //*
  // === Test sequence ===
  initial begin


    // Wait for fetch_enable_i  
    wait (fetch_enable_i);
    @(posedge clk_i);

    
    read_and_check(BASE_ADDR , 32'hB7); 
    read_and_check(BASE_ADDR+32'h4, 32'h08008067);
    read_and_check(BASE_ADDR+32'h8, 32'h0BAD_D000);

    //
    //   // === End test ===
    @(posedge clk_i);
    $display("[Time %0t] ✅ Test complete", $time);
    $finish;
  end
endmodule
