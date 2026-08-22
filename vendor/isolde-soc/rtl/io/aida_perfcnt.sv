// Copyleft 2026 ISOLDE

`ifdef TARGET_VERILATOR
`define AIDA_PERFCNT_CSV_LOG
`elsif TARGET_QUESTASIM
`define AIDA_PERFCNT_CSV_LOG
`endif


module aida_perfcnt
  import isolde_tcdm_pkg::*;
#(
    parameter logic [31:0] PERFCNT_ADDR = 32'h8000_000C
) (
    input logic clk_i,
    input logic rst_ni,

    // CPU MMIO interface
    input  isolde_tcdm_pkg::req_t data_req,
    output isolde_tcdm_pkg::rsp_t data_rsp,

    // Observation-only memory interfaces
    input isolde_tcdm_pkg::req_t imem_req_i,
    input isolde_tcdm_pkg::rsp_t imem_rsp_i,

    input isolde_tcdm_pkg::req_t dmem_req_i,
    input isolde_tcdm_pkg::rsp_t dmem_rsp_i,

    input isolde_tcdm_pkg::req_t stack_req_i,
    input isolde_tcdm_pkg::rsp_t stack_rsp_i
);

  // --------------------------------------------------------------------------
  // Register map
  //
  // PERFCNT_ADDR + 0x00 : measurement ID / control
  // PERFCNT_ADDR + 0x04 : elapsed cycles
  // PERFCNT_ADDR + 0x08 : instruction-memory writes
  // PERFCNT_ADDR + 0x0C : instruction-memory reads
  // PERFCNT_ADDR + 0x10 : data-memory writes
  // PERFCNT_ADDR + 0x14 : data-memory reads
  // PERFCNT_ADDR + 0x18 : stack-memory writes
  // PERFCNT_ADDR + 0x1C : stack-memory reads
  // --------------------------------------------------------------------------



  // --------------------------------------------------------------------------
  // Types
  // --------------------------------------------------------------------------

  typedef enum logic [2:0] {
    IDLE,
    LATCH,
    WAIT,
    DIFF,
    PRINT
  } perfcnt_state_t;


  typedef struct packed {
    logic [31:0] cnt_wr;
    logic [31:0] cnt_rd;
  } mem_io_t;


  typedef struct packed {
    logic [31:0] id;
    logic [31:0] cycle_counter;

    mem_io_t imem;
    mem_io_t dmem;
    mem_io_t stack_mem;
  } perfcnt_t;


  // --------------------------------------------------------------------------
  // Free-running performance counters
  // --------------------------------------------------------------------------

  logic [31:0] cycle_counter_q;

  logic [31:0] imem_cnt_wr_q;
  logic [31:0] imem_cnt_rd_q;

  logic [31:0] dmem_cnt_wr_q;
  logic [31:0] dmem_cnt_rd_q;

  logic [31:0] stack_cnt_wr_q;
  logic [31:0] stack_cnt_rd_q;

  logic imem_fire;
  logic dmem_fire;
  logic stack_fire;


  /*
   * Count only accepted requests.
   *
   * This keeps the counters independent from the implementation of
   * the actual memory and avoids counting requests stalled by gnt.
   */
  assign imem_fire  = imem_req_i.req && imem_rsp_i.gnt;

  assign dmem_fire  = dmem_req_i.req && dmem_rsp_i.gnt;

  assign stack_fire = stack_req_i.req && stack_rsp_i.gnt;


  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin

      cycle_counter_q <= '0;

      imem_cnt_wr_q   <= '0;
      imem_cnt_rd_q   <= '0;

      dmem_cnt_wr_q   <= '0;
      dmem_cnt_rd_q   <= '0;

      stack_cnt_wr_q  <= '0;
      stack_cnt_rd_q  <= '0;

    end else begin

      cycle_counter_q <= cycle_counter_q + 32'd1;


      // Instruction memory
      if (imem_fire) begin
        if (imem_req_i.we) imem_cnt_wr_q <= imem_cnt_wr_q + 32'd1;
        else imem_cnt_rd_q <= imem_cnt_rd_q + 32'd1;
      end


      // Data memory
      if (dmem_fire) begin
        if (dmem_req_i.we) dmem_cnt_wr_q <= dmem_cnt_wr_q + 32'd1;
        else dmem_cnt_rd_q <= dmem_cnt_rd_q + 32'd1;
      end


      // Stack memory
      if (stack_fire) begin
        if (stack_req_i.we) stack_cnt_wr_q <= stack_cnt_wr_q + 32'd1;
        else stack_cnt_rd_q <= stack_cnt_rd_q + 32'd1;
      end

    end
  end


  // --------------------------------------------------------------------------
  // Performance-counter FSM
  // --------------------------------------------------------------------------

  perfcnt_state_t perfcnt_state_q;
  perfcnt_state_t perfcnt_state_d;

  perfcnt_t perfcnt_start_q;
  perfcnt_t perfcnt_result_q;

  logic perfcnt_ctrl_write;


  /*
   * First write to PERFCNT_ADDR:
   *   start measurement
   *
   * Second write to PERFCNT_ADDR:
   *   stop measurement
   */
  assign perfcnt_ctrl_write = data_rsp.gnt && data_req.we && (data_req.addr == PERFCNT_ADDR);


  always_comb begin

    perfcnt_state_d = perfcnt_state_q;

    case (perfcnt_state_q)

      IDLE: begin
        if (perfcnt_ctrl_write) perfcnt_state_d = LATCH;
      end


      LATCH: begin
        perfcnt_state_d = WAIT;
      end


      WAIT: begin
        if (perfcnt_ctrl_write) perfcnt_state_d = DIFF;
      end


      DIFF: begin
        perfcnt_state_d = PRINT;
      end


      PRINT: begin
        perfcnt_state_d = IDLE;
      end


      default: begin
        perfcnt_state_d = IDLE;
      end

    endcase
  end


  // --------------------------------------------------------------------------
  // Snapshot / difference calculation
  // --------------------------------------------------------------------------

  always_ff @(posedge clk_i or negedge rst_ni) begin

    if (!rst_ni) begin

      perfcnt_state_q  <= IDLE;
      perfcnt_start_q  <= '0;
      perfcnt_result_q <= '0;

    end else begin

      perfcnt_state_q <= perfcnt_state_d;


      case (perfcnt_state_d)

        // --------------------------------------------------------------------
        // Capture the starting counters.
        // --------------------------------------------------------------------
        LATCH: begin

          perfcnt_start_q.id <= data_req.data;

          perfcnt_start_q.cycle_counter <= cycle_counter_q;


          perfcnt_start_q.imem.cnt_wr <= imem_cnt_wr_q;
          perfcnt_start_q.imem.cnt_rd <= imem_cnt_rd_q;


          perfcnt_start_q.dmem.cnt_wr <= dmem_cnt_wr_q;
          perfcnt_start_q.dmem.cnt_rd <= dmem_cnt_rd_q;


          perfcnt_start_q.stack_mem.cnt_wr <= stack_cnt_wr_q;
          perfcnt_start_q.stack_mem.cnt_rd <= stack_cnt_rd_q;

        end


        // --------------------------------------------------------------------
        // Calculate measurement result.
        // --------------------------------------------------------------------
        DIFF: begin

          perfcnt_result_q.id <= perfcnt_start_q.id;


          perfcnt_result_q.cycle_counter <= cycle_counter_q - perfcnt_start_q.cycle_counter;


          perfcnt_result_q.imem.cnt_wr <= imem_cnt_wr_q - perfcnt_start_q.imem.cnt_wr;
          perfcnt_result_q.imem.cnt_rd <= imem_cnt_rd_q - perfcnt_start_q.imem.cnt_rd;


          perfcnt_result_q.dmem.cnt_wr <= dmem_cnt_wr_q - perfcnt_start_q.dmem.cnt_wr;
          perfcnt_result_q.dmem.cnt_rd <= dmem_cnt_rd_q - perfcnt_start_q.dmem.cnt_rd;


          perfcnt_result_q.stack_mem.cnt_wr <= stack_cnt_wr_q - perfcnt_start_q.stack_mem.cnt_wr;
          perfcnt_result_q.stack_mem.cnt_rd <= stack_cnt_rd_q - perfcnt_start_q.stack_mem.cnt_rd;

        end


        default: begin
        end

      endcase

    end
  end


  // --------------------------------------------------------------------------
  // TCDM response
  // --------------------------------------------------------------------------

  logic        rsp_valid_q;
  logic [31:0] rsp_data_q;


  assign data_rsp.gnt   = rst_ni && data_req.req;

  assign data_rsp.valid = rsp_valid_q;
  assign data_rsp.err   = 1'b0;
  assign data_rsp.data  = rsp_data_q;


  always_ff @(posedge clk_i or negedge rst_ni) begin

    if (!rst_ni) begin

      rsp_valid_q <= 1'b0;
      rsp_data_q  <= '0;

    end else begin

      rsp_valid_q <= data_rsp.gnt;

      if (data_rsp.gnt) begin

        if (!data_req.we) begin

          case (data_req.addr)

            PERFCNT_ADDR + 32'h00: rsp_data_q <= perfcnt_result_q.id;

            PERFCNT_ADDR + 32'h04: rsp_data_q <= perfcnt_result_q.cycle_counter;

            PERFCNT_ADDR + 32'h08: rsp_data_q <= perfcnt_result_q.imem.cnt_wr;

            PERFCNT_ADDR + 32'h0C: rsp_data_q <= perfcnt_result_q.imem.cnt_rd;

            PERFCNT_ADDR + 32'h10: rsp_data_q <= perfcnt_result_q.dmem.cnt_wr;

            PERFCNT_ADDR + 32'h14: rsp_data_q <= perfcnt_result_q.dmem.cnt_rd;

            PERFCNT_ADDR + 32'h18: rsp_data_q <= perfcnt_result_q.stack_mem.cnt_wr;

            PERFCNT_ADDR + 32'h1C: rsp_data_q <= perfcnt_result_q.stack_mem.cnt_rd;

            default: rsp_data_q <= '0;

          endcase

        end else begin

          rsp_data_q <= '0;

        end
      end

    end
  end


  // ==========================================================================
  // Simulation-only CSV logging
  // ==========================================================================

`ifdef AIDA_PERFCNT_CSV_LOG

  integer perfcnt_fh;


  // --------------------------------------------------------------------------
  // Open performance-counter CSV file.
  // --------------------------------------------------------------------------
  initial begin
    perfcnt_fh = $fopen("perfcnt.csv", "w");

    if (perfcnt_fh == 0) begin
      $error("[AIDA_PERFCNT] Unable to open perfcnt.csv");
    end else begin
      //   $display("[AIDA_PERFCNT] Performance counters log: perfcnt.csv");

      $fwrite(
          perfcnt_fh,
          "id,cycles,reads[imemory],writes[dmemory],reads[dmemory],writes[stack],reads[stack],arch\n");

      $fflush(perfcnt_fh);
      //   $display("[AIDA_PERFCNT] CSV header written and flushed");
    end
  end


  // --------------------------------------------------------------------------
  // Log completed measurements.
  //
  // PRINT occurs one cycle after DIFF, so perfcnt_result_q already contains
  // the completed measurement.
  // --------------------------------------------------------------------------

  always_ff @(posedge clk_i) begin

    if (rst_ni && (perfcnt_state_q == PRINT) && (perfcnt_fh != 0)) begin

      $fwrite(perfcnt_fh, "%0d,%0d,%0d,%0d,%0d,%0d,%0d,AIDA\n", perfcnt_result_q.id,
              perfcnt_result_q.cycle_counter, perfcnt_result_q.imem.cnt_rd,
              perfcnt_result_q.dmem.cnt_wr, perfcnt_result_q.dmem.cnt_rd,
              perfcnt_result_q.stack_mem.cnt_wr, perfcnt_result_q.stack_mem.cnt_rd);

      $fflush(perfcnt_fh);

    end

  end


  // --------------------------------------------------------------------------
  // Close CSV file at simulation shutdown.
  // --------------------------------------------------------------------------

  final begin

    if (perfcnt_fh != 0) $fclose(perfcnt_fh);

  end

`endif  // AIDA_PERFCNT_CSV_LOG


endmodule


`ifdef AIDA_PERFCNT_CSV_LOG
`undef AIDA_PERFCNT_CSV_LOG
`endif
