// Copyleft 2024

interface isolde_fetch2exec_if #(
    parameter int unsigned IMM32_OPS = 4
) (
    // Clock and Reset
    input logic clk_i,  // Clock signal
    input logic rst_ni  // Active-low reset signal
);
  logic exec_rst_ni;  // execute  block active-low reset signal
  logic isolde_decoder_enable;  // custom instr is decoded
  logic isolde_decoder_illegal_instr;  // unsupported custom instr encountered
  logic isolde_decoder_ready;  //decoder ready
  logic stall_isolde_decoder;  //stall decoder 
  //
  isolde_decoder_pkg::isolde_opcode_e isolde_opcode;  //decoded instruction
  logic [2:0] func3;  //instr[14-12]
  logic [1:0] funct2;
  logic [31:0] isolde_decoder_instr;  // Offloaded instruction
  logic [IMM32_OPS  -1:0][31:0] isolde_decoder_imm32;        // Immediate operands for the offloaded instruction
  logic [IMM32_OPS  -1:0] isolde_decoder_imm32_valid;  // Validity of the immediate operands
endinterface
