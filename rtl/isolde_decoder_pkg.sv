// Copyleft 2024

package isolde_decoder_pkg;

  typedef enum logic [5:0] {
    isolde_opcode_invalid,
    isolde_opcode_nop,
    isolde_opcode_vle32_4,
    isolde_opcode_gemm,
    isolde_opcode_conv2d,
    isolde_opcode_R_type,
    isolde_opcode_redmule,
    isolde_opcode_redmule_gemm,
    isolde_opcode_redmule_gemm1
  } isolde_opcode_e;

  typedef struct packed {
    isolde_opcode_e opcode;
    logic [2:0]     vlen_words;
  } isolde_decoded_t;


  function automatic isolde_decoded_t decode_isolde_opcode(
      input logic [6:0] opCode_i, input logic [2:0] nnn_i, input logic [6:0] func7_i);
    isolde_decoded_t result;
    // Define constants for custom encodings
    localparam logic [6:0] RISCV_ENC_GE80 = 7'b1111111;  // Custom opcode for GE80 (160-bit or 96-bit instructions)
    localparam logic [6:0] RISCV_ENC_64   = 7'b0111111;  // Custom opcode for 64-bit instruction (2 words)
    localparam logic [6:0] RISCV_ENC_C0   = 7'b0001011;  // Custom-0 opcode for 32-bit instruction (1 word) 
    localparam logic [6:0] RISCV_ENC_C1   = 7'b0101011;  // Custom-1 opcode for 32-bit instruction (1 word) 
    localparam logic [6:0] RISCV_ENC_C2   = 7'b1011011;  // Custom-2 opcode for 32-bit instruction (1 word) 
    localparam logic [6:0] RISCV_ENC_C3   = 7'b1111011;  // Custom-3 opcode for 32-bit instruction (1 word) 

    localparam logic [2:0] RISCV_ENC_GE80_N5 = 3'h5;  // Custom encoding for N5 (5 words)
    localparam logic [2:0] RISCV_ENC_GE80_N3 = 3'h3;  // Custom encoding for N5 (4 words)
    localparam logic [2:0] RISCV_ENC_GE80_N1 = 3'h1;  // Custom encoding for N1 (3 words)
    begin
      // -------------------------------------------------------------------------
      // Defaults 
      // -------------------------------------------------------------------------
      result.opcode     = isolde_opcode_invalid;
      result.vlen_words = 3'd1;

      case (opCode_i)
        RISCV_ENC_GE80: begin
          if (nnn_i == RISCV_ENC_GE80_N5) begin
            result.vlen_words = 5;
            case (func7_i)
              7'b0000011: result.opcode = isolde_opcode_vle32_4;
              default: result.opcode = isolde_opcode_nop;
            endcase
          end else if (nnn_i == RISCV_ENC_GE80_N3) begin
            result.vlen_words = 4;
            case (func7_i)
              7'b0000100: result.opcode = isolde_opcode_redmule_gemm;
              7'b0000011: result.opcode = isolde_opcode_vle32_4;
              default: result.opcode = isolde_opcode_nop;
            endcase
          end else if (nnn_i == RISCV_ENC_GE80_N1) begin
            result.vlen_words = 3;
            case (func7_i)
              7'b0000000: result.opcode = isolde_opcode_conv2d;
              7'b0000011: result.opcode = isolde_opcode_vle32_4;
              default: result.opcode = isolde_opcode_nop;
            endcase
          end else result.opcode = isolde_opcode_invalid;
        end
        RISCV_ENC_64: begin
          result.vlen_words = 2;
          case (func7_i)
            7'b0000111: result.opcode = isolde_opcode_gemm;
            default: result.opcode = isolde_opcode_nop;
          endcase
        end
        RISCV_ENC_C0: begin
          result.vlen_words = 1;
          result.opcode = isolde_opcode_R_type;
        end
        RISCV_ENC_C1: begin
          result.vlen_words = 1;
          case (nnn_i)  //a.k.a funct3
            3'b000: begin
              case (func7_i[1:0])
                2'b00:   result.opcode = isolde_opcode_redmule;
                2'b01:   result.opcode = isolde_opcode_redmule_gemm1;
                default: result.opcode = isolde_opcode_invalid;
              endcase
            end
            3'b001:  result.opcode = isolde_opcode_invalid;  //reserved
            3'b011:  result.opcode = isolde_opcode_invalid;  //reserved
            default: result.opcode = isolde_opcode_invalid;
          endcase
        end
      endcase
      return result;
    end
  endfunction

endpackage
