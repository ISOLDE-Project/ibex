// Copyleft 2024 ISOLDE
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//

module tb_sram_mem #(
    parameter ID = 0,  // ID of the memory bank (default 0)
    parameter BASE_ADDR = 0,  // Base address for memory access (default 0)
    parameter MEMORY_SIZE = 1024,  // Size of the memory (default 1024 entries)
    parameter DELAY_CYCLES = 0  // Number of clock cycles to delay  operations (default 2)
) (
    input  logic                  clk_i,
    input  logic                  rst_ni,
    input  isolde_tcdm_pkg::req_t req_i,
    output isolde_tcdm_pkg::rsp_t rsp_o
);

  logic [ 7:0] memory                                               [MEMORY_SIZE];





  logic [ 1:0] misalignment;
  logic [31:0] index;
  // Programmable delay counters for each read port
  logic [31:0] delay_counter;  // Delay counter for each memory port

  int          cnt_wr = 0;
  int          cnt_rd = 0;

  // Generate block for each memory port


  //assign rsp_o.gnt= req_i.req;  // Always grant access for simplicity
  assign misalignment = req_i.addr[1:0];  // Get the last 2 bits of the address

  always_comb begin
    if (rst_ni && req_i.req) rsp_o.gnt = (delay_counter == 0) ? req_i.req : 0;
    else rsp_o.gnt = 0;

    case (misalignment)
      2'b00: begin
        index = (req_i.addr - BASE_ADDR);
      end
      2'b01: begin
        // If addr is ...xx01, read from addr-1, addr, addr+1
        index = (req_i.addr - BASE_ADDR) - 1;
      end
      2'b10: begin
        // If addr is ...xx10, read from addr-2, addr-1, addr
        index = (req_i.addr - BASE_ADDR) - 2;
      end
      2'b11: begin
        // If addr is ...xx11, read from addr-3, addr-2, addr-1
        index = (req_i.addr - BASE_ADDR) - 3;
      end
    endcase

  end

  // Always block to process read and write operations
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      rsp_o.data  <= '0;
      rsp_o.valid <= '0;
    end else begin

      if (rsp_o.gnt) begin
        rsp_o.gnt <= 0;
        delay_counter <= DELAY_CYCLES;
        if (req_i.we) begin  // Write
          cnt_wr += 1;
          if (req_i.be[0]) memory[index] <= req_i.data[7:0];
          if (req_i.be[1]) memory[index+1] <= req_i.data[15:8];
          if (req_i.be[2]) memory[index+2] <= req_i.data[23:16];
          if (req_i.be[3]) memory[index+3] <= req_i.data[31:24];
          //loop back
          rsp_o.data  <= req_i.data;
          rsp_o.valid <= 1'b1;
        end else begin  //read

          cnt_rd += 1;
          rsp_o.data[7:0] <= memory[index];
          rsp_o.data[15:8] <= memory[index+1];
          rsp_o.data[23:16] <= memory[index+2];
          rsp_o.data[31:24] <= memory[index+3];

          rsp_o.valid <= 1'b1;
        end
      end else begin  //~rsp_o.gnt
        delay_counter <= req_i.req ? delay_counter - 1 : DELAY_CYCLES;
        rsp_o.data <= '0;
        rsp_o.valid <= 1'b0;
      end

    end
  end





endmodule  // tb_tcdm_verilator
