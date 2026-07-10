
module isolde_decoder_top
  import isolde_register_file_pkg::RegDataWidth, isolde_register_file_pkg::RegCount, isolde_register_file_pkg::RegSize, isolde_register_file_pkg::RegAddrWidth;
(
    input logic clk_i,
    input logic rst_ni,
    // Interface to IF stage
    input logic instr_valid_i,
    input  logic [31:0]      instr_rdata_i,           // from IF-ID pipeline registers
    input logic  instr_exec_i,

    // output to ID stage
    output logic illegal_custom_instr_o,  //custom illegal operation
    output logic isolde_stall_fetch_o,
    output logic isolde_decoder_busy_o,
    //ISOLDE Register file interface
    isolde_register_file_if.cpu isolde_rf_bus,
    isolde_x_register_file_if.cpu x_rf_bus,
    // eXtension interface
    isolde_cv_x_if.cpu_compressed xif_compressed_if,
    isolde_cv_x_if.cpu_issue xif_issue_if,
    isolde_cv_x_if.cpu_commit xif_commit_if,
    isolde_cv_x_if.cpu_mem xif_mem_if,
    isolde_cv_x_if.cpu_mem_result xif_mem_result_if,
    isolde_cv_x_if.cpu_result xif_result_if
);

  logic isolde_decoder_stalled;
  isolde_fetch2exec_if fetch_exec_conn ();

  isolde_register_file_pkg::isolde_rf_raddr_t isolde_rf_raddr;
  isolde_register_file_pkg::isolde_rf_rdata_t isolde_rf_rdata;
  //
  isolde_register_file_pkg::isolde_rf_waddr_t isolde_rf_wp_addr;
  isolde_register_file_pkg::isolde_rf_wdata_t isolde_rf_wp_echo;
  isolde_register_file_pkg::write_port_t isolde_rf_wp;
  //
  isolde_x_register_file_pkg::isolde_x_rf_addr_t x_rf_addr;
  isolde_x_register_file_pkg::isolde_x_rf_addr_t x_rf_addr_exec;
  isolde_x_register_file_pkg::isolde_x_rf_data_t x_rf_data;

  isolde_register_file_interconnect isolde_register_file_interconnect_i (
      .isolde_rf_if(isolde_rf_bus),
      .raddr_i(isolde_rf_raddr),
      .rdata_o(isolde_rf_rdata),
      .wp_i(isolde_rf_wp),
      .waddr_o(isolde_rf_wp_addr),
      .wp_echo_o(isolde_rf_wp_echo)

  );

  isolde_x_register_file_interconnect isolde_x_register_file_interconnect_i (
      .x_rf_bus(x_rf_bus),
      .raddr_i (x_rf_addr),
      .rdata_o (x_rf_data),
      .raddr_o (x_rf_addr_exec)

  );

  isolde_decoder isolde_decoder_i (
      .clk_i(clk_i),
      .rst_ni(rst_ni),
      .isolde_decoder_instr_exec_i(instr_exec_i),
      .isolde_decoder_instr_valid_i(instr_valid_i),
      .isolde_decoder_instr_rdata_i(instr_rdata_i),
      .isolde_decoder_illegal_instr_o(illegal_custom_instr_o),
      .isolde_decoder_busy_o(isolde_decoder_busy_o),
      .isolde_decoder_stalled_o(isolde_decoder_stalled),

      //ISOLDE register file
      .isolde_rf_raddr_o      (isolde_rf_raddr),
      .isolde_rf_wp_o         (isolde_rf_wp),
      .x_rf_addr_o            (x_rf_addr),
      .isolde_decoder_exec_bus(fetch_exec_conn.dec)
  );



  assign isolde_stall_fetch_o = ~isolde_decoder_stalled;
  ///////////////////////////
  // ISOLDE  execute block //
  ///////////////////////////


  isolde_exec_block isolde_exec_block_i (
      .clk_i                   (clk_i),
      .rst_ni                  (rst_ni),
      .isolde_rf_raddr_i       (isolde_rf_raddr),
      .isolde_rf_rdata_i       (isolde_rf_rdata),
      .isolde_rf_waddr_i       (isolde_rf_wp_addr),
      .isolde_rf_wecho_i       (isolde_rf_wp_echo),
      .x_rf_addr_i             (x_rf_addr_exec),
      .x_rf_data_i             (x_rf_data),
      .isolde_exec_from_decoder(fetch_exec_conn.exec),
      .isolde_exec_busy_o      (),
      // eXtension interface
      .xif_compressed_if,
      .xif_issue_if,
      .xif_commit_if,
      .xif_mem_if,
      .xif_mem_result_if,
      .xif_result_if
  );

endmodule : isolde_decoder_top
