// Copyleft ISOLDE 2025


// helper functions
function automatic logic [31:0] jal(logic [4:0] rd, logic [20:0] imm);
  return {imm[20], imm[10:1], imm[11], imm[19:12], rd, 7'h6f};
endfunction

function automatic logic [31:0] jalr(logic [4:0] rd, logic [4:0] rs1, logic [11:0] offset);
  return {offset[11:0], rs1, 3'b0, rd, 7'h67};
endfunction

function automatic logic [31:0] lui(logic [4:0] rd, logic [19:0] uimm);
  return {uimm, rd, 7'b0110111};
endfunction



module isolde_boot_rom #(
    parameter BASE_ADDR = 32'h0000_0080  // ROM base address
) (
    input logic clk_i,

    input  isolde_tcdm_pkg::req_t boot_req_i,
    output isolde_tcdm_pkg::rsp_t boot_rsp_o
);

  localparam MEMORY_SIZE = 2;  // Size of the memory in bytes

  // Manually encoded instructions using BASE_ADDR
  // LUI x1, BASE_ADDR[31:12]
  localparam logic [31:0] instr_lui = lui(5'h1, BASE_ADDR[31:12]);

  // JALR x0, x1, BASE_ADDR[11:0]
  localparam logic [31:0] instr_jalr = jalr(5'h0, 5'h1, BASE_ADDR[11:0]);


  logic [1:0] misalignment;
  logic [1:0] index;



  always_comb begin
    boot_rsp_o.gnt = boot_req_i.req;  // Always grant access for simplicity

    index =  boot_req_i.addr [3:2];

  end

  // Always block to process read and write operations
  always_ff @(posedge clk_i) begin

    if (boot_rsp_o.gnt) begin

      if (boot_req_i.we) begin  // Write
        //loop back
        boot_rsp_o.data  <= 32'hDEAD_BEEF;
        boot_rsp_o.valid <= 1'b1;
      end else begin  //read
        case (index)
          0: boot_rsp_o.data <= instr_lui;
          1: boot_rsp_o.data <= instr_jalr;

          default: boot_rsp_o.data <= 32'h0BAD_D000;
        endcase
        boot_rsp_o.valid <= 1'b1;
      end
    end else begin  //~rsp_o.gnt

      boot_rsp_o.data  <= '0;
      boot_rsp_o.valid <= 1'b0;
    end

  end
endmodule

