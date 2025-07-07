`timescale 1ns / 1ps

module tb_isolde_log_interconnect (
    input logic clk_i,
    input logic rst_ni,
    input logic fetch_enable_i

);

  localparam int unsigned N_MASTERS = 2;

  isolde_tcdm_if core_if[1] ();



  isolde_tcdm_pkg::opaq_req_t cores_req[0:0];
  isolde_tcdm_pkg::opaq_rsp_t cores_rsp[0:0];
  isolde_tcdm_pkg::opaq_req_t mems_req [1:0];
  isolde_tcdm_pkg::opaq_rsp_t mems_rsp [1:0];


  assign core_if[0].rsp = isolde_tcdm_pkg::from_opaq_rsp(cores_rsp[0]);
  assign cores_req[0]   = isolde_tcdm_pkg::to_opaq_req(core_if[0].req);



  //   for (genvar i = 0; i < N_MASTERS; i++) begin : tcdm_bank

  //     tb_sram_mem #(
  //         .ID(i)
  //     ) i_bank (
  //         .clk_i,
  //         .rst_ni,
  //         .req_i(mems_req[i]),
  //         .rsp_o(mems_rsp[i])
  //     );

  //   end

  tb_sram_mem #(
      .ID(0)
  ) i_bank_0 (
      .clk_i,
      .rst_ni,
      .req_i(mems_req[0]),
      .rsp_o(mems_rsp[0])
  );
  tb_sram_mem #(
      .ID(1)
  ) i_bank_1 (
      .clk_i,
      .rst_ni,
      .req_i(mems_req[1]),
      .rsp_o(mems_rsp[1])
  );

  //DUT
  isolde_log_interconnect #(
      .N_SLAVES (1),
      .N_MASTERS(2)
  ) dut (
      .clk_i,
      .rst_ni,
      .cores_req_i(cores_req),
      .cores_rsp_o(cores_rsp),
      .mems_req_o (mems_req),
      .mems_rsp_i (mems_rsp)
  );

  // Input signal generation
  //https://github.com/verilator/verilator/issues/5210
  //*
  //if you need <= assignment in initial block, change the block into allways, otherways it will be treated as =, blocking assigment.
  //*
  initial begin
    $readmemh("tb/a.hex", tb_isolde_log_interconnect.i_bank_0.memory);
    $readmemh("tb/b.hex", tb_isolde_log_interconnect.i_bank_1.memory);
    //always begin
    do @(posedge clk_i); while (!fetch_enable_i);
    core_if[0].req.req  = 1;
    core_if[0].req.we   = 0;
    core_if[0].req.addr = 32'h1000_0000;
    core_if[0].req.data = 32'hDEAD_C0DE;
    @(posedge clk_i);
    core_if[0].req.req = 0;
    //do@(posedge clk_i) ;while(!mems_if[0].rsp.valid);
    repeat (10) @(posedge clk_i);
    core_if[0].req.req  = 1;
    core_if[0].req.addr = 32'h1000_0004;
    @(posedge clk_i);
    core_if[0].req.req = 0;
    repeat (10) @(posedge clk_i);
    core_if[0].req.req  = 1;
    core_if[0].req.addr = 32'h1000_0008;
    @(posedge clk_i);
    core_if[0].req.req = 0;
    repeat (10) @(posedge clk_i);

    //   // === End test ===
    @(posedge clk_i);
    $display("[Time %0t] ✅ Test complete", $time);
    $finish;
  end
endmodule
