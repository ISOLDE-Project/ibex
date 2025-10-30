// Copyyleft 2025 ISOLDE
// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

///////////////////////////////////////////////////////////////////////////////
//
// Description: UART top level
//
///////////////////////////////////////////////////////////////////////////////
//
// Authors    : Antonio Pullini (pullinia@iis.ee.ethz.ch)
//
///////////////////////////////////////////////////////////////////////////////


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

    input isolde_tcdm_pkg::req_t uart_req_i,
    output isolde_tcdm_pkg::rsp_t uart_rsp_o


);

  localparam logic [15:0] BAUD_DIV = CLOCK_FREQ / BAUD_RATE;

  logic [1:0] s_uart_status;

  logic       s_data_tx_valid;
  logic       s_tx_done;
  logic       s_data_tx_ready;
  logic [7:0] s_data_tx;



  // Always block to process read/write operations
  always_ff @(posedge sys_clk_i or negedge rstn_i) begin
    if (!rstn_i) begin
      // Reset all state
      s_data_tx                    <= '0;
    end else begin
      if (uart_req_i.req) begin
        if (uart_req_i.we) begin
          // Write operation
           uart_rsp_o.gnt <= s_data_tx_ready;
          if(s_data_tx_ready) begin
           
             s_data_tx <= uart_req_i.data[7:0];
             s_data_tx_valid <= 1;
             uart_rsp_o <= uart_req_i.data[7:0];  // echo back         
          end
        end else begin
          // Read operation
         uart_rsp_o.data <= s_data_tx;
                 // Mark response as valid
         uart_rsp_o.valid <= 1'b1; 
         uart_rsp_o.gnt <= 1;
        end

      end else begin
                 uart_rsp_o.valid <= 1'b0; 
         uart_rsp_o.gnt <= 0;
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




endmodule  // udma_uart_top
