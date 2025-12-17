// Copyleft 2025 ISOLDE 


module aida_io
  import isolde_tcdm_pkg::*;
  import aida_lca_package::*;
#(
    parameter logic [31:0] MMIO_ADDR = 32'h8000_0000
) (
    input logic clk_i,
    input logic rst_ni,
    //
    output aida_io_pkg::aida_pads_o_t pads_o,
    `ifdef TARGET_RV_DEBUG
    //
    input isolde_tcdm_pkg::req_t dm_sba_req,
    output isolde_tcdm_pkg::rsp_t dm_sba_rsp,
    `endif
    //  
    input isolde_tcdm_pkg::req_t data_req,
    output isolde_tcdm_pkg::rsp_t data_rsp
    `ifdef TARGET_VERILATOR
    ,output logic[31:0] sim_exit_code_o,
    output logic sim_exit_valid_o    
`endif    

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
      '{start_addr: MMADDR_EXIT, end_addr: MMADDR_EXIT + 32'h3},
      '{start_addr: MMADDR_PRINT, end_addr: MMADDR_PRINT + 32'h3}
  };

  // /********************************************************/
  // /**           Interface Definitions                   **/
  // /*******************************************************/

  isolde_tcdm_if tcdm_mmio_muxed ();
  isolde_tcdm_pkg::req_t mmio_reqs[IO_LAST_IDX];
  isolde_tcdm_pkg::rsp_t mmio_rsps[IO_LAST_IDX];

  /********************************************************/
  /**           MUX                                     **/
  /*******************************************************/
  `ifdef TARGET_RV_DEBUG
  isolde_mux_tcdm i_mux_dm_data_mmio (
      .clk_i,
      .rst_ni,
      .req_1_i(dm_sba_req),
      .req_2_i(data_req),
      .rsp_1_o(dm_sba_rsp),
      .rsp_2_o(data_rsp),
      .tcdm_master_o(tcdm_mmio_muxed)
  );
`else
  assign tcdm_mmio_muxed.req =data_req;
  assign data_rsp= tcdm_mmio_muxed.rsp;
`endif
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

  /********************************************************/
  /**          EXIT CODE                               **/
  /*******************************************************/


  isolde_tcdm_if tcdm_mmio_exit ();
  assign tcdm_mmio_exit.req = mmio_reqs[IO_EXIT_IDX];
  assign mmio_rsps[IO_EXIT_IDX] = tcdm_mmio_exit.rsp;

  logic [31:0] exit_code;
  logic        rsp_valid_q;

  // Output register connections
  assign tcdm_mmio_exit.rsp.data = exit_code;
  assign tcdm_mmio_exit.rsp.valid = rsp_valid_q;
  assign tcdm_mmio_exit.rsp.err = 1'b0;
  assign tcdm_mmio_exit.rsp.gnt = rst_ni && tcdm_mmio_exit.req.req;

`ifdef TARGET_VERILATOR
  assign sim_exit_code_o  = exit_code; 
  assign sim_exit_valid_o = rsp_valid_q;
`endif    


  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      exit_code   <= '0;
      rsp_valid_q <= 1'b0;
    end else begin
      // default: no response unless we accept a request this cycle
      rsp_valid_q <= 1'b0;

      if (tcdm_mmio_exit.rsp.gnt) begin
        if (tcdm_mmio_exit.req.we) begin
          exit_code  <= tcdm_mmio_exit.req.data;          
        end 
        rsp_valid_q <= 1'b1;
      end
    end
  end


  /********************************************************/
  /**           UART                             **/
  /*******************************************************/

  isolde_tcdm_if tcdm_mmio_print ();
  assign tcdm_mmio_print.req = mmio_reqs[IO_PRINT_IDX];
  assign mmio_rsps[IO_PRINT_IDX] = tcdm_mmio_print.rsp;



  isolde_uart_top #(
      .CLOCK_FREQ(aida_io_pkg::UART_CLOCK_FREQ),
      .BAUD_RATE (aida_io_pkg::UART_BAUD_RATE)
  ) i_isolde_uart_top (
      .sys_clk_i(clk_i),
      .rstn_i(rst_ni),
      .uart_tx_o(pads_o.uart_tx_o),
      .tcdm_slave_print_i(tcdm_mmio_print)

  );

endmodule
