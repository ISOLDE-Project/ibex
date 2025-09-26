// Copyleft ISOLDE 2025

module isolde_boot_rom #(
    parameter logic [31:0] base_addr = 32'h0000_0080  // ROM base address
)(
    input  logic         clk_i,
    input  logic         req_i,
    input  logic [31:0]  addr_i,
    output logic [31:0]  rdata_o
);

    localparam int RomSize = 2;

    // Manually encoded instructions using base_addr
    // LUI x1, base_addr[31:12]
    localparam logic [31:0] instr_lui = 
        (base_addr & 32'hFFFFF000) | (5'd1 << 7) | 32'h00000037;  // rd = x1, opcode = LUI

    // JALR x0, x1, base_addr[11:0]
    localparam logic [31:0] instr_jalr =
        (base_addr[11:0] << 20) |     // imm[11:0]
        (5'd1 << 15) |                // rs1 = x1
        (3'd0 << 12) |                // funct3 = 000
        (5'd0 << 7)  |                // rd = x0
        7'b1100111;                   // opcode = JALR

    logic [1:0] addr_q;

    // Address calculation
    assign addr_q = addr_i[3:2]; // word-aligned address indexing

    // ROM output logic
    always_comb begin
        case (addr_q)
            2: rdata_o = instr_jalr;
            3: rdata_o = instr_lui;
            default: rdata_o = 32'b0;
        endcase
    end

endmodule

module isolde_boot_rom_wrp #(
    parameter logic [31:0] base_addr = 32'h0000_0080  // ROM base address
)(
    input  logic         clk_i,
    input  logic         req_i,
    input isolde_tcdm_pkg::req_t rom_req_i,
    output isolde_tcdm_pkg::rsp_t rom_rsp_o
);
isolde_boot_rom #(.base_addr(base_addr)) isolde_boot_rom(
    .req_i(rom_req_i.req),
    .addr_i(rom_req_i.addr),
    .rdata_o(rom_rsp_o.data)
);
endmodule