// Simulation memory model for Vivado (ZCU104)

/*

MEMORY_PRIMITIVE is ignored in simulation, but kept for consistency with synthesis.

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

 tb_tcdm_mem #(
      .BASE_ADDR(BASE_ADDR),
      .MEMORY_SIZE(MEMORY_SIZE*4), // in bytes
      .DELAY_CYCLES(DELAY_CYCLES)
  ) u_tcdm_mem (
      .clk_i(clk_i),
      .rst_ni(rst_ni),
      .tcdm_slave_i(tcdm_slave_i)
  );

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
      .MEMORY_SIZE(MEMORY_SIZE), //  number of 32-bit words
      .DELAY_CYCLES(DELAY_CYCLES),
      .MEMORY_PRIMITIVE(MEMORY_PRIMITIVE)
  ) dut (
      .clk_i(clk_i),
      .rst_ni(rst_ni),
      .tcdm_slave_i(tcdm_intf.slave)  // connect the modport
  );

endmodule
