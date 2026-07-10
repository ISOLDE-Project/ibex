// Copyleft
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * Fetch variable length instruction
 *
 * Decodes RISC-V variable lenght encoded instructions 
 */

`include "prim_assert.sv"

module isolde_fetch_vleninstr (
    input  logic              clk_i,
    input  logic              rst_ni,
    input  logic              vlen_instr_req_i,    //request for next instruction
    input  logic              word_instr_ready_i,  // Signals that word_instr_i can be used
    input  logic [31:0]       word_instr_i,        // Instruction input from icache
    output logic              word_instr_req_o,    // request a word_instr_i
    output logic [ 4:0][31:0] vlen_instr_o,        // In-order succession of maximum 5 word_instr_i
    output logic [ 2:0]       vlen_instr_words_o,  // Instruction length in words
    output logic              vlen_instr_ready_o   // vlen_instr_o is ready to use
);

 

  // Extract the opcode and nnn fields from the instruction
  logic [6:0] opCode;
  logic [2:0] nnn;  // Encodes bits 14-12

  // Define constants for custom encodings
  localparam logic [6:0] RISCV_ENC_GE80 = 7'b1111111;  // Custom opcode for GE80 (160-bit or 96-bit instructions)
  localparam logic [6:0] RISCV_ENC_64   = 7'b0111111;  // Custom opcode for 64-bit instruction (2 words)

  localparam logic [2:0] RISCV_ENC_GE80_N5 = 3'h5;  // Custom encoding for N5 (5 words)
  localparam logic [2:0] RISCV_ENC_GE80_N3 = 3'h3;  // Custom encoding for N5 (4 words)
  localparam logic [2:0] RISCV_ENC_GE80_N1 = 3'h1;  // Custom encoding for N1 (3 words)

  // Internal control signals

  logic [2:0] wr_ptr;  // Write pointer to store fetched words into vlen_instr_o
  logic             _word_instr_req_o;  // request a word_instr_i
  logic [3:0][31:0] des_instr;  // In-order succession of maximum 5 word_instr_i
  logic [2:0]       _vlen_instr_words_o;  // Instruction length in words
  logic             _vlen_instr_ready_o;  // _vlen_instr_o is ready to use

  // Extract opcode and nnn
  assign opCode = word_instr_i[6:0];     // Extracting opcode bits
  assign nnn    = word_instr_i[14:12];   // Extracting bits [14:12] for nnn



  assign word_instr_req_o = vlen_instr_req_i;
  assign vlen_instr_ready_o = word_instr_ready_i;



  //assign word_instr_req_o = _word_instr_req_o;
  //assign vlen_instr_ready_o = _vlen_instr_ready_o;





  assign vlen_instr_words_o =_vlen_instr_words_o;

  //output the deserialiser
  assign vlen_instr_o[0] = word_instr_i;
  assign vlen_instr_o[1] = des_instr[0];
  assign vlen_instr_o[2] = des_instr[1];
  assign vlen_instr_o[3] = des_instr[2];
  assign vlen_instr_o[4] = des_instr[3];



  always_ff @(posedge clk_i, negedge rst_ni) begin
    if (!rst_ni) begin
      wr_ptr <= 0;
      des_instr <= '0;
      _vlen_instr_words_o <= 0;
    end else begin

      if (word_instr_ready_i & vlen_instr_req_i) begin
        des_instr[3] <= des_instr[2];
        des_instr[2] <= des_instr[1];
        des_instr[1] <= des_instr[0];
        des_instr[0] <= word_instr_i;
        //compute instruction length based on opCode and nnn
        case (opCode)
          RISCV_ENC_GE80: begin
            if (nnn == RISCV_ENC_GE80_N5) begin
              _vlen_instr_words_o <= 5;  // 5-word instruction (160 bits)
            end else if (nnn == RISCV_ENC_GE80_N3) begin
              _vlen_instr_words_o <= 4;  // 3-word instruction (96 bits)
            end else if (nnn == RISCV_ENC_GE80_N1) begin
              _vlen_instr_words_o <= 3;  // 3-word instruction (96 bits)
            end else begin
`ifndef SYNTHESIS
              // Assert if unknown nnn is encountered
              $fatal("Unsupported custom instruction: nnn = %0d", nnn);
`endif
            end
          end

          RISCV_ENC_64: begin
            _vlen_instr_words_o <= 2;  // 2-word instruction (64 bits)
          end

          default: begin
            _vlen_instr_words_o <= 1;  // Single-word instruction (32 bits)
          end
        endcase
      end
    end
  end




endmodule

module if_id_instr_fifo_5 #(
  parameter int INSTR_W = 32
) (
  input  logic               clk_i,
  input  logic               rst_ni,

  // From IF
  input  logic               if_valid_i,
  input  logic [INSTR_W-1:0] if_instr_i,
  output logic               if_ready_o,

  // To ID
  output logic               id_valid_o,
  output logic [INSTR_W-1:0] id_instr_o,
  input  logic               id_ready_i
);

  localparam int DEPTH = 5;
  localparam int PTR_W = $clog2(DEPTH);

  logic [INSTR_W-1:0] mem [0:DEPTH-1];
  logic [PTR_W-1:0]   wr_ptr, rd_ptr;
  logic [PTR_W:0]     count;

  logic push, pop;

  assign push = if_valid_i & if_ready_o;
  assign pop  = id_valid_o & id_ready_i;

  assign if_ready_o = (count < DEPTH);
  assign id_valid_o = (count > 0);
  assign id_instr_o = mem[rd_ptr];

  function automatic logic [PTR_W-1:0] ptr_inc(input logic [PTR_W-1:0] ptr);
    if (ptr == DEPTH-1)
      ptr_inc = '0;
    else
      ptr_inc = ptr + 1'b1;
  endfunction

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wr_ptr <= '0;
      rd_ptr <= '0;
      count  <= '0;
    end else begin
      unique case ({push, pop})
        2'b10: begin
          mem[wr_ptr] <= if_instr_i;
          wr_ptr      <= ptr_inc(wr_ptr);
          count       <= count + 1'b1;
        end

        2'b01: begin
          rd_ptr <= ptr_inc(rd_ptr);
          count  <= count - 1'b1;
        end

        2'b11: begin
          mem[wr_ptr] <= if_instr_i;
          wr_ptr      <= ptr_inc(wr_ptr);
          rd_ptr      <= ptr_inc(rd_ptr);
          count       <= count;
        end

        default: begin
          // no-op
        end
      endcase
    end
  end

endmodule
