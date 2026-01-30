// Copyleft

module isolde_exec_block
  import isolde_decoder_pkg::*;
  import isolde_register_file_pkg::RegAddrWidth;
  import isolde_register_file_pkg::RegSize, isolde_register_file_pkg::RegDataWidth;
  import isolde_register_file_pkg::*;
#(
    parameter string LogName = "isolde_exec_block.log"
) (
    // Clock and Reset
    input logic clk_i,  // Clock signal
    input logic rst_ni,  // Active-low reset signal
    // ISOLDE register file
    isolde_rf_raddr_t  isolde_rf_raddr_i,
    isolde_rf_rdata_t  isolde_rf_rdata_i,
    isolde_rf_waddr_t isolde_rf_waddr_i,
    isolde_rf_wdata_t isolde_rf_wecho_i,
    isolde_x_register_file_if.cpu x_rf_bus,
    isolde_fetch2exec_if.exec isolde_exec_from_decoder,
    output logic isolde_exec_busy_o,
    // eXtension interface
    isolde_cv_x_if.cpu_compressed xif_compressed_if,
    isolde_cv_x_if.cpu_issue xif_issue_if,
    isolde_cv_x_if.cpu_commit xif_commit_if,
    isolde_cv_x_if.cpu_mem xif_mem_if,
    isolde_cv_x_if.cpu_mem_result xif_mem_result_if,
    isolde_cv_x_if.cpu_result xif_result_if
);

  /********************************************************/
  /**   tie-off unused interfaces                        **/
  /********************************************************/
  // Compressed interface
  assign xif_compressed_if.compressed_valid = 0;
  assign xif_compressed_if.compressed_req = '0;
  // Commit interface
  // NA
  // Memory (request/response) interface
  assign xif_mem_if.mem_ready = 0;
  assign xif_mem_if.mem_resp = '0;
  // Memory result interface
  assign xif_mem_result_if.mem_result_valid = 0;
  assign xif_mem_result_if.mem_result = '0;
  // Result interface
  assign xif_result_if.result_ready = 0;

`ifndef SYNTHESIS
  integer log_fh;

  initial begin
    log_fh = $fopen(LogName, "w");
  end

  final begin
    $fclose(log_fh);
  end
`endif
  typedef struct packed {
    logic [2:0] cnt_max;  // 0 => immediate
  } isolde_exec_action_t;

  // FSM states
  typedef enum logic [2:0] {
    IDLE,
    START,  //start execution
    WAIT    //wait for completion
  } state_t;

  localparam isolde_exec_action_t EXEC_NOP = '{3'd0};
  isolde_exec_action_t exec_action;

  state_t ievli_state, ievli_next;



  isolde_opcode_e isolde_opcode_dec;  //decoded isolde opcode
  logic [2:0] cnt, cnt_max;



  logic exec_req, exec_gnt, exec_dne;
  assign exec_req = isolde_exec_from_decoder.isolde_exec_req;
  assign isolde_exec_from_decoder.isolde_exec_gnt = exec_gnt;
  assign isolde_exec_from_decoder.isolde_exec_dne = exec_dne;
  assign isolde_opcode_dec = isolde_exec_from_decoder.isolde_opcode;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cnt <= 0;
      cnt_max <= 0;
      ievli_state <= IDLE;
      exec_action = EXEC_NOP;
      xif_issue_if.issue_valid <= 0;
      xif_issue_if.issue_req   <= '0;
    end else begin
      ievli_state <= ievli_next;
      case (ievli_next)
        START: begin
          cnt <= 0;
          case (isolde_opcode_dec)
            isolde_opcode_nop: exec_action = start_nop();
            isolde_opcode_redmule: exec_action = start_nop_redmule();
            isolde_opcode_R_type: exec_action = start_nop_RType();
            isolde_opcode_vle32_4: exec_action = start_vle32_4();
            isolde_opcode_gemm: exec_action = start_gemm();
            isolde_opcode_conv2d: exec_action = start_conv2d();
            isolde_opcode_redmule_gemm: exec_action = start_redmule_gemm();
            isolde_opcode_redmule_gemm1: exec_action = start_redmule_gemm1();
            default: begin
              exec_action = EXEC_NOP;
            end
          endcase
          cnt_max <= exec_action.cnt_max;
        end
        WAIT: begin
          cnt <= cnt + 1;
          xif_issue_if.issue_valid <= 0;
        end

      endcase
    end
  end


  always_comb begin
    exec_dne = 0;
    exec_gnt = 0;
    isolde_exec_busy_o = 0;
    ievli_next = IDLE;
    case (ievli_state)
      IDLE: begin
        if (exec_req) begin
          exec_gnt = 1;
          ievli_next = START;
          isolde_exec_busy_o = 1;
        end
      end

      START: begin
        isolde_exec_busy_o = 1;
        ievli_next = WAIT;
      end

      WAIT: begin
        if (cnt == cnt_max) begin
          exec_dne = 1;
          isolde_exec_busy_o = 0;
          ievli_next = IDLE;
        end
      end
    endcase
  end



  function automatic isolde_exec_action_t start_nop();
`ifndef SYNTHESIS
    $fwrite(log_fh, " --- @t=%t    %s\n", $time, "isolde_exec_block::start_nop");
`endif
    begin
      return EXEC_NOP;  // resume with next cycle
    end
  endfunction

  function automatic isolde_exec_action_t start_vle32_4();
`ifndef SYNTHESIS
    $fwrite(log_fh, " --- %s\n", "isolde_exec_block::start_vle32_4");
    $fwrite(log_fh, "    @rd=%d: [ %d, %d, %d, %d ]\n", isolde_rf_waddr_i, isolde_rf_wecho_i[0],
            isolde_rf_wecho_i[1], isolde_rf_wecho_i[2], isolde_rf_wecho_i[3]);
`endif
    begin
      return EXEC_NOP;  // resume with next cycle
    end
  endfunction



  function automatic isolde_exec_action_t start_nop_RType();
`ifndef SYNTHESIS
    $fwrite(log_fh, " --- @t=%t    %s\n", $time, "isolde_exec_block::start_nop_RType");
    $fwrite(log_fh, "    instr=%h\n", isolde_exec_from_decoder.isolde_decoder_instr);
    $fwrite(log_fh, "    @rd1=%d: %h\n", x_rf_bus.raddr[0], x_rf_bus.rdata[0]);
    $fwrite(log_fh, "    @rs1=%d: %h\n", x_rf_bus.raddr[1], x_rf_bus.rdata[1]);
    $fwrite(log_fh, "    @rs2=%d: %h\n", x_rf_bus.raddr[2], x_rf_bus.rdata[2]);
`endif
    begin
      xif_issue_if.issue_req.instr <= isolde_exec_from_decoder.isolde_decoder_instr;
      xif_issue_if.issue_req.rs[0] <= x_rf_bus.rdata[1];  // rs1
      xif_issue_if.issue_req.rs[1] <= x_rf_bus.rdata[2];  // rs2
      xif_issue_if.issue_req.rs[2] <= x_rf_bus.rdata[0];  //rd
      xif_issue_if.issue_req.rs_valid <= 3'b111;
      xif_issue_if.issue_valid <= 1;
      //
      return EXEC_NOP;  // resume with next cycle
    end
  endfunction


  function automatic isolde_exec_action_t start_nop_redmule();
`ifndef SYNTHESIS
    $fwrite(log_fh, " --- @t=%t    %s\n", $time, "isolde_exec_block::start_nop_redmule");
    $fwrite(log_fh, "    instr=%h\n", isolde_exec_from_decoder.isolde_decoder_instr);
    $fwrite(log_fh, "    @rs1=%d: %h\n", x_rf_bus.raddr[0], x_rf_bus.rdata[0]);
    $fwrite(log_fh, "    @rs2=%d: %h\n", x_rf_bus.raddr[1], x_rf_bus.rdata[1]);
    $fwrite(log_fh, "    @rs3=%d: %h\n", x_rf_bus.raddr[2], x_rf_bus.rdata[2]);
`endif
    begin
      xif_issue_if.issue_req.instr <= isolde_exec_from_decoder.isolde_decoder_instr;
      xif_issue_if.issue_req.rs[0] <= x_rf_bus.rdata[0];  //rs1
      xif_issue_if.issue_req.rs[1] <= x_rf_bus.rdata[1];  // rs2
      xif_issue_if.issue_req.rs[2] <= x_rf_bus.rdata[2];  // rs3
      xif_issue_if.issue_req.rs_valid <= 3'b111;
      xif_issue_if.issue_valid <= 1;
      //
      return EXEC_NOP;  // resume with next cycle
    end
  endfunction


  function automatic isolde_exec_action_t start_gemm();
`ifndef SYNTHESIS
    //  $fwrite(fh, "Simulation Time: %t\n", $time); // Print the current simulation time
    $fwrite(log_fh, " --- @t=%t    %s\n", $time, "isolde_exec_block::start_gemm");
    $fwrite(log_fh, "  func3=%b\n", isolde_exec_from_decoder.func3);
    $fwrite(log_fh, "    @rd1=%d: %h\n", x_rf_bus.raddr[0], x_rf_bus.rdata[0]);
    $fwrite(log_fh, "    @rs1=%d: %h\n", x_rf_bus.raddr[1], x_rf_bus.rdata[1]);
    $fwrite(log_fh, "    @rs2=%d: %h\n", x_rf_bus.raddr[2], x_rf_bus.rdata[2]);
    $fwrite(log_fh, "    @rs3=%d: %h\n", x_rf_bus.raddr[3], x_rf_bus.rdata[3]);
    $fwrite(log_fh, "    @rs4=%d: [ %d, %d, %d, %d ]\n", isolde_rf_raddr_i[0],
            isolde_rf_rdata_i[0][0], isolde_rf_rdata_i[0][1], isolde_rf_rdata_i[0][2],
            isolde_rf_rdata_i[0][3]);
    $fwrite(log_fh, "    @rs5=%d: [ %d, %d, %d, %d ]\n", isolde_rf_raddr_i[1],
            isolde_rf_rdata_i[1][0], isolde_rf_rdata_i[1][1], isolde_rf_rdata_i[1][2],
            isolde_rf_rdata_i[1][3]);
    $fwrite(log_fh, "  funct2=%b\n", isolde_exec_from_decoder.funct2);

`endif
    begin
      return '{cnt_max: 3'd4};  // wait cycles time for completion
    end
  endfunction

  function automatic isolde_exec_action_t start_redmule_gemm();
`ifndef SYNTHESIS
    //  $fwrite(fh, "Simulation Time: %t\n", $time); // Print the current simulation time
    $fwrite(log_fh, " --- @t=%t    %s\n", $time, "isolde_exec_block::start_redmule_gemm");
    $fwrite(log_fh, "    instr=%h\n", isolde_exec_from_decoder.isolde_decoder_instr);
    $fwrite(log_fh, "    @rd1=%d: %h\n", x_rf_bus.raddr[0], x_rf_bus.rdata[0]);
    $fwrite(log_fh, "    @rs1=%d: %h\n", x_rf_bus.raddr[1], x_rf_bus.rdata[1]);
    $fwrite(log_fh, "    @rs2=%d: %h\n", x_rf_bus.raddr[2], x_rf_bus.rdata[2]);
    for (int i = 0; i < isolde_exec_from_decoder.IMM32_OPS; i++) begin
      $fwrite(log_fh, "  imm32[%0d]: 0x%h (valid: %b)\n", i,
              isolde_exec_from_decoder.isolde_decoder_imm32[i],
              isolde_exec_from_decoder.isolde_decoder_imm32_valid[i]);
    end

`endif
    begin
      xif_issue_if.issue_req.instr <= isolde_exec_from_decoder.isolde_decoder_instr;
      xif_issue_if.issue_req.rs[0] <= x_rf_bus.rdata[0];  //rs1
      xif_issue_if.issue_req.rs[1] <= x_rf_bus.rdata[1];  // rs2
      xif_issue_if.issue_req.rs[2] <= x_rf_bus.rdata[2];  // rs3
      xif_issue_if.issue_req.rs_valid <= 3'b111;
      xif_issue_if.issue_req.imm32 <= isolde_exec_from_decoder.isolde_decoder_imm32;
      xif_issue_if.issue_req.imm32_valid <= isolde_exec_from_decoder.isolde_decoder_imm32_valid;
      xif_issue_if.issue_valid <= 1;
      //
      return EXEC_NOP;  // resume with next cycle
    end
  endfunction

  function automatic isolde_exec_action_t start_redmule_gemm1();
`ifndef SYNTHESIS
    $display(" --- @t=%t    %s\n", $time, "isolde_exec_block::start_redmule_gemm1");
    $fwrite(log_fh, " --- @t=%t    %s\n", $time, "isolde_exec_block::start_redmule_gemm1");
    $fwrite(log_fh, "    instr=%h\n", isolde_exec_from_decoder.isolde_decoder_instr);
    $fwrite(log_fh, "    func3=%b\n", isolde_exec_from_decoder.func3);
    $fwrite(log_fh, "    @rd1=%d: %h\n", x_rf_bus.raddr[0], x_rf_bus.rdata[0]);
    $fwrite(log_fh, "    @rs1=%d: %h\n", x_rf_bus.raddr[1], x_rf_bus.rdata[1]);
    $fwrite(log_fh, "    @rs2=%d: %h\n", x_rf_bus.raddr[2], x_rf_bus.rdata[2]);
    $fwrite(log_fh, "    @rs3=%d: [ %d, %d, %d, %d ]\n", isolde_rf_raddr_i[0],
            isolde_rf_rdata_i[0][0], isolde_rf_rdata_i[0][1], isolde_rf_rdata_i[0][2],
            isolde_rf_rdata_i[0][3]);
`endif
    begin
      xif_issue_if.issue_req.instr <= 32'h087332ff;  //hack to simplify redmule instruction decoder
      xif_issue_if.issue_req.rs[0] <= x_rf_bus.rdata[0];  //rs1
      xif_issue_if.issue_req.rs[1] <= x_rf_bus.rdata[1];  // rs2
      xif_issue_if.issue_req.rs[2] <= x_rf_bus.rdata[2];  // rs3
      xif_issue_if.issue_req.rs_valid <= 3'b111;
      xif_issue_if.issue_req.imm32[0] <= isolde_rf_rdata_i[0][1];
      xif_issue_if.issue_req.imm32[1] <= isolde_rf_rdata_i[0][2];
      xif_issue_if.issue_req.imm32[2] <= isolde_rf_rdata_i[0][3];
      xif_issue_if.issue_req.imm32_valid <= 3'b111;
      xif_issue_if.issue_valid <= 1;
      //
      return EXEC_NOP;  // resume with next cycle
    end
  endfunction


  function automatic isolde_exec_action_t start_conv2d();
`ifndef SYNTHESIS
    $fwrite(log_fh, " --- @t=%t    %s\n", $time, "isolde_exec_block::start_conv2d");
    $fwrite(log_fh, "    instr=%h\n", isolde_exec_from_decoder.isolde_decoder_instr);
    $fwrite(log_fh, "    func3=%b\n", isolde_exec_from_decoder.func3);
    $fwrite(log_fh, "    @rd1=%d: %h\n", x_rf_bus.raddr[0], x_rf_bus.rdata[0]);
    $fwrite(log_fh, "    @rs1=%d: %h\n", x_rf_bus.raddr[1], x_rf_bus.rdata[1]);
    $fwrite(log_fh, "    @rs2=%d: %h\n", x_rf_bus.raddr[2], x_rf_bus.rdata[2]);
    //
    $fwrite(log_fh, "    @rd2=%d: [ %d, %d, %d, %d ]\n", isolde_rf_raddr_i[0],
            isolde_rf_rdata_i[0][0], isolde_rf_rdata_i[0][1], isolde_rf_rdata_i[0][2],
            isolde_rf_rdata_i[0][3]);
    $fwrite(log_fh, "    @rs3=%d: [ %d, %d, %d, %d ]\n", isolde_rf_raddr_i[1],
            isolde_rf_rdata_i[1][0], isolde_rf_rdata_i[1][1], isolde_rf_rdata_i[1][2],
            isolde_rf_rdata_i[1][3]);
    $fwrite(log_fh, "    @rs4=%d: [ %d, %d, %d, %d ]\n", isolde_rf_raddr_i[2],
            isolde_rf_rdata_i[2][0], isolde_rf_rdata_i[2][1], isolde_rf_rdata_i[2][2],
            isolde_rf_rdata_i[2][3]);
    $fwrite(log_fh, "    @rs5=%d: %h\n", x_rf_bus.raddr[3], x_rf_bus.rdata[3]);
    //
    $fwrite(log_fh, "    @rs6=%d: [ %d, %d, %d, %d ]\n", isolde_rf_raddr_i[3],
            isolde_rf_rdata_i[3][0], isolde_rf_rdata_i[3][1], isolde_rf_rdata_i[3][2],
            isolde_rf_rdata_i[3][3]);
    $fwrite(log_fh, "    @rs7=%d: [ %d, %d, %d, %d ]\n", isolde_rf_raddr_i[4],
            isolde_rf_rdata_i[4][0], isolde_rf_rdata_i[4][1], isolde_rf_rdata_i[4][2],
            isolde_rf_rdata_i[4][3]);

`endif
    begin
      return '{cnt_max: 3'd4};  // wait cycles time for completion
    end
  endfunction


endmodule
