// Copyleft 2025 ISOLDE 


module aida_soc_io
  import isolde_tcdm_pkg::*;
  import aida_lca_package::*;
#(
    parameter logic [31:0] MMIO_ADDR = 32'h8000_0000
) (
    input logic clk_i,
    input logic rst_ni,
    //
    output aida_io_pkg::aida_pads_o_t pads_o,
    //
    input isolde_tcdm_pkg::req_t dm_sba_req,
    output isolde_tcdm_pkg::rsp_t dm_sba_rsp,
    //  
    input isolde_tcdm_pkg::req_t data_req,
    output isolde_tcdm_pkg::rsp_t data_rsp
);

  // Internal MMIO address mapping
  localparam logic [31:0] MMADDR_EXIT = MMIO_ADDR + 32'h0;
  localparam logic [31:0] MMADDR_PRINT = MMIO_ADDR + 32'h4;
  localparam logic [31:0] MMADDR_PERF = MMIO_ADDR + 32'hC;

  /********************************************************/
  /**          Router configurations                     **/
  /*******************************************************/

  typedef enum {
    IO_EXIT_IDX,
    IO_PRINT_IDX,
    IO_LAST_IDX
  } mmio_map_idx_t;

  // 
  localparam addr_range_t mmio_map[IO_LAST_IDX] = '{
      '{start_addr: MMADDR_EXIT, end_addr: MMADDR_EXIT + 32'h4},
      '{start_addr: MMADDR_PRINT, end_addr: MMADDR_PRINT + 32'h4}
  };

  // /********************************************************/
  // /**           Interface Definitions                   **/
  // /*******************************************************/

  // // === Data port ===

  isolde_tcdm_if tcdm_mmio_muxed ();

  // assign tcdm_mmio_muxed.req = dm_sba_req;
  // assign dm_sba_rsp = tcdm_mmio_muxed.rsp;

  isolde_tcdm_pkg::req_t mmio_reqs[IO_LAST_IDX];
  isolde_tcdm_pkg::rsp_t mmio_rsps[IO_LAST_IDX];

  /********************************************************/
  /**           MUX                                     **/
  /*******************************************************/
  isolde_mux_tcdm i_mux_dm_sb_spm (
      .clk_i,
      .rst_ni,
      .req_2_i(dm_sba_req),
      .req_1_i(data_req),
      .rsp_2_o(dm_sba_rsp),
      .rsp_1_o(data_rsp),
      .tcdm_master_o(tcdm_mmio_muxed)
  );

  // assign  tcdm_mmio_muxed.req =dm_sba_req;
  // assign dm_sba_rsp= tcdm_mmio_muxed.rsp;
  /********************************************************/
  /**           Router(s)                                **/
  /*******************************************************/

  isolde_router #(
      .N_RULES(IO_LAST_IDX),
      .ADDR_RANGES(mmio_map)
  ) i_isolde_router_mmio (
      .clk_i,
      .rst_ni,
      .tcdm_slave_i(tcdm_mmio_muxed),
      .req_o       (mmio_reqs),
      .rsp_i       (mmio_rsps)
  );

  logic [31:0] exit_code;



  // // Grant logic: active only when reset is inactive
  // assign mmio_rsps[IO_EXIT_IDX].gnt = rst_ni && mmio_reqs[IO_EXIT_IDX].req;

  // // Always block to process read/write operations
  // always_ff @(posedge clk_i or negedge rst_ni) begin
  //   if (!rst_ni) begin
  //     // Reset all state
  //     exit_code                    <= '0;
  //     mmio_rsps[IO_EXIT_IDX].data  <= '0;
  //     mmio_rsps[IO_EXIT_IDX].valid <= 1'b0;
  //   end else begin
  //     // Default outputs every cycle
  //     mmio_rsps[IO_EXIT_IDX].data  <= 32'hDEAD_BEEF;  // debug pattern
  //     mmio_rsps[IO_EXIT_IDX].valid <= 1'b0;

  //     if (mmio_rsps[IO_EXIT_IDX].gnt) begin
  //       if (mmio_reqs[IO_EXIT_IDX].we) begin
  //         // Write operation
  //         exit_code <= mmio_reqs[IO_EXIT_IDX].data;
  //         mmio_rsps[IO_EXIT_IDX].data <= mmio_reqs[IO_EXIT_IDX].data;  // echo back
  //       end else begin
  //         // Read operation
  //         mmio_rsps[IO_EXIT_IDX].data <= exit_code;
  //       end
  //       // Mark response as valid
  //       mmio_rsps[IO_EXIT_IDX].valid <= 1'b1;
  //     end
  //   end
  // end



  // isolde_uart_top #(
  //     .CLOCK_FREQ(115200)
  // ) i_isolde_uart_top (
  //     .sys_clk_i(clk_i),
  //     .rstn_i(rst_ni),
  //     .uart_tx_o(pads_o.uart_tx_o),
  //     .uart_req_i(mmio_reqs[IO_PRINT_IDX]),
  //     .uart_rsp_o(mmio_rsps[IO_PRINT_IDX])
  // );
 isolde_tcdm_if tcdm_mmio_print ();
  assign  tcdm_mmio_print.req = mmio_reqs[IO_PRINT_IDX];
  assign  mmio_rsps[IO_PRINT_IDX] = tcdm_mmio_print.rsp;
  tcdm_mem #(
      .MEMORY_SIZE(2048),
      //.DELAY_CYCLES(IMEM_LATENCY),
      .MEMORY_PRIMITIVE("ultra")
  ) i_print_memory (
      .clk_i,
      .rst_ni,
      .tcdm_slave_i(tcdm_mmio_print)
  );

endmodule
