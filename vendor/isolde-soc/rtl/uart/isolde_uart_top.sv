// Copyyleft 2025 ISOLDE



module isolde_uart_top #(
    /**
    Parity bit generation and check configuration bitfield:
- 1'b0: disabled
- 1'b1: enabled
    */
    parameter bit PARITY_ENABLE = 0,
    /**
    Character length bitfield:
- 2'b00: 5 bits
- 2'b01: 6 bits
- 2'b10: 7 bits
- 2'b11: 8 bits
    */
    parameter logic [1:0] UART_BITS = 2'b11,
    /**
    Stop bits length bitfield:
- 1'b0: 1 stop bit
- 1'b1: 2 stop bits
    */
    parameter bit STOP_BITS = 1'b0,
    parameter CLOCK_FREQ = 100_000_000,  // sys_clk_i value in Hz
    parameter BAUD_RATE = 115200

) (
    input logic sys_clk_i,
    input logic rstn_i,

    output logic uart_tx_o,

    isolde_tcdm_if.slave tcdm_slave_print_i
);

  localparam logic [15:0] BAUD_DIV = CLOCK_FREQ / BAUD_RATE;

  logic [0:0] s_uart_status;

  logic       s_data_tx_valid;
  logic       s_tx_done;
  logic       s_data_tx_ready;
  logic [7:0] s_data_tx;
  logic [7:0] echo_data_tx;

  logic       rsp_valid_q;



  // Output register connections
  assign tcdm_slave_print_i.rsp.data  = echo_data_tx;
  assign tcdm_slave_print_i.rsp.valid = rsp_valid_q;
  assign tcdm_slave_print_i.rsp.err   = 1'b0;
  assign tcdm_slave_print_i.rsp.gnt   = rstn_i && tcdm_slave_print_i.req.req;

  always_ff @(posedge sys_clk_i or negedge rstn_i) begin
    if (!rstn_i) begin
      echo_data_tx <= '0;
      rsp_valid_q  <= 1'b0;
    end else begin
      // default: no response unless we accept a request this cycle
      rsp_valid_q <= 1'b0;

      if (tcdm_slave_print_i.rsp.gnt) begin
        if (tcdm_slave_print_i.req.we) begin
          echo_data_tx <= tcdm_slave_print_i.req.data;
        end
        rsp_valid_q <= 1'b1;
      end
    end
  end


  udma_uart_tx u_uart_tx (
      .clk_i          (sys_clk_i),
      .rstn_i         (rstn_i),
      .tx_o           (uart_tx_o),
      .busy_o         (s_uart_status[0]),
      .cfg_en_i       (1'b1),
      .cfg_div_i      (BAUD_DIV),
      .cfg_parity_en_i(PARITY_ENABLE),
      .cfg_bits_i     (UART_BITS),
      .cfg_stop_bits_i(STOP_BITS),
      .tx_data_i      (s_data_tx),
      .tx_valid_i     (s_data_tx_valid),
      .tx_ready_o     (s_data_tx_ready),
      .tx_done_o      (s_tx_done)
  );




endmodule  // isolde_uart_top
