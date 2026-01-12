// Copyleft 2024 ISOLDE
// see https://ibex-core.readthedocs.io/en/latest/03_reference/load_store_unit.html, Protocol
interface isolde_fetch2exec_if #(
    parameter int unsigned IMM32_OPS = 4
);

  //
  logic isolde_exec_req;  // The isolde decoder sets this high
  logic isolde_exec_gnt;  // The exec_block then answers with isolde_exec_qnt set high as soon as it is ready to serve the request. 
                          // This may happen in the same cycle as the request was sent or any number of cycles later.
  logic isolde_exec_dne;  // The exec_bloc answers with isolde_exec_dne set high for exactly one cycle to signal the completion.
                          // This may happen one or more cycles after the grant has been asserted. I
  //
  isolde_decoder_pkg::isolde_opcode_e isolde_opcode;  //decoded instruction
  logic [2:0] func3;  //instr[14-12]
  logic [1:0] funct2;
  logic [31:0] isolde_decoder_instr;  // Offloaded instruction
  logic [IMM32_OPS  -1:0][31:0] isolde_decoder_imm32;        // Immediate operands for the offloaded instruction
  logic [IMM32_OPS  -1:0] isolde_decoder_imm32_valid;  // Validity of the immediate operands

  modport dec(
      output isolde_exec_req,
      input isolde_exec_gnt,
      input isolde_exec_dne,
      output isolde_opcode,
      output func3,
      output funct2,
      output isolde_decoder_instr,
      output isolde_decoder_imm32,
      output isolde_decoder_imm32_valid

  );

  modport exec(
      input isolde_exec_req,
      output isolde_exec_gnt,
      output isolde_exec_dne,
      input isolde_opcode,
      input func3,
      input funct2,
      input isolde_decoder_instr,
      input isolde_decoder_imm32,
      input isolde_decoder_imm32_valid
  );
endinterface
