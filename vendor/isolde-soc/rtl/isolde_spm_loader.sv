// Copyleft ISOLDE 2026
//
// isolde_spm_loader
// -----------------
// Moves 32-bit words between data memory (DMEM) and a tile scratchpad (SPM),
// replacing the CPU store loop in bsp/spm.c:spm_write()/spm_read().
//
// This is NOT a DMA. It has one channel, one transfer in flight, a linear
// source address and exactly one destination layout: the 9-bank SPM row
// geometry. That is enough, because DMEM is a single 32-bit port and therefore
// caps throughput at one word per cycle no matter how clever the engine is.
//
// SPM row geometry (must match bsp/spm.c exactly)
// -----------------------------------------------
//   * a row is 9 words: banks 0..8, at narrow offsets (row<<6) + (bank<<2)
//   * a row carries 8 *payload* words; bank 8 duplicates bank 0 of the next row
//   * rows before the last receive src[8r+0 .. 8r+8]
//   * the final row receives only src[8r+0 .. 8r+7]; bank 8 is untouched
//
// The sequencer walks (row, bank) and derives the source word index by simply
// NOT incrementing it on the bank 8 -> bank 0 wrap. No divides, no modulo-9.
// The final bank-8 access is omitted because there is no following payload row.
// A transfer of LEN payload words therefore performs LEN + N_ROWS - 1 accesses.
//
// Tile selection is NOT handled here. Writes leave on the ordinary narrow SPM
// port and are steered by isolde_tile_router from CSR_ISOLDE_TILESEL, exactly
// like a CPU store. Set TILESEL, then start.
//
// TCDM protocol assumed (see tb_tcdm_mem.sv):
//   * req asserted, gnt combinational in the same cycle
//   * rsp.valid exactly one cycle after gnt, carrying read data
//   * one outstanding transaction
//
module isolde_spm_loader #(
    // Register block base; must match the SPMLD_IDX rule added to
    // isolde_cluster.sv addr_map.
    parameter int unsigned REG_ADDR = 32'h8000_9000,
    // Base of the narrow SPM window. The tile router contains an
    // isolde_addr_shim with START_ADDR = SPM_NARROW_ADDR_BASE, so addresses
    // arriving on spm_o must be absolute, not row-relative.
    parameter int unsigned SPM_BASE = 32'h8000_1000,
    // Deassert req for one cycle out of DUTY to stop a long burst from
    // starving RedMulE on the tile's HCI port (the narrow port has strict
    // priority in isolde_hci_interconnect). Set 0 to disable throttling.
    parameter int unsigned DUTY     = 0
) (
    input logic clk_i,
    input logic rst_ni,
    // === register block (CPU writes descriptors here) ===
    isolde_tcdm_if.slave cfg_i,

    // === master port to data memory ===
    isolde_tcdm_if.master dmem_o,

    // === master port to the narrow SPM window (via isolde_tile_router) ===
    isolde_tcdm_if.master spm_o,

    // === completion event, OR-ed into core_evt in isolde_cluster.sv ===
    output logic done_o,
    output logic busy_o
);

  import isolde_tcdm_pkg::*;
  localparam int unsigned PAYLOAD_PER_ROW = 8;  // NUM_BANKS-1
  localparam int unsigned BANKS_PER_ROW = 9;  // NUM_BANKS
  localparam int unsigned ROW_SHIFT = 6;  // BANK_OFFSET_SHIFT
  localparam int unsigned BANK_SHIFT = 2;
  localparam logic [3:0] BANK_LAST = 4'd8;  // BANKS_PER_ROW-1
  // ------------------------------------------------------------------------
  // Register block
  // ------------------------------------------------------------------------
  //   0x00 SRC      DMEM byte address of the first payload word
  //   0x04 DST_ROW  first SPM row index
  //   0x08 LEN      payload words; MUST be a multiple of 8
  //   0x0C CTRL     [0] start (self-clearing), [1] dir 0=load 1=store,
  //                 [2] negate_fp16 on LOAD: XOR 0x8000 into each FP16 lane
  //   0x10 STATUS   [0] busy, [1] done (write 1 to clear)
  // ------------------------------------------------------------------------
  logic [31:0] reg_src_q, reg_dstrow_q, reg_len_q;
  logic reg_dir_q;
  logic reg_negate_q;
  logic start_pulse;
  logic done_q;
  logic cfg_sel, cfg_wr, cfg_rd;
  logic [3:0] cfg_off;

  assign cfg_sel = cfg_i.req.req;
  assign cfg_wr  = cfg_sel & cfg_i.req.we;
  assign cfg_rd  = cfg_sel & ~cfg_i.req.we;
  logic [31:0] cfg_addr;
  assign cfg_addr = cfg_i.req.addr - REG_ADDR;
  assign cfg_off  = cfg_addr[5:2];

  // The whole rsp struct must have exactly ONE driver, so the registered
  // fields live in cfg_rsp_q and the combinational fields are merged in here.
  rsp_t cfg_rsp_q;
  always_comb begin
    cfg_i.rsp     = cfg_rsp_q;
    cfg_i.rsp.gnt = cfg_sel;  // single-cycle grant, as tcdm_mem does
    cfg_i.rsp.err = 1'b0;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      reg_src_q    <= '0;
      reg_dstrow_q <= '0;
      reg_len_q    <= '0;
      reg_dir_q    <= 1'b0;
      reg_negate_q <= 1'b0;
      start_pulse  <= 1'b0;
      cfg_rsp_q    <= '0;
    end else begin
      start_pulse     <= 1'b0;
      cfg_rsp_q.valid <= cfg_sel;
      cfg_rsp_q.data  <= '0;
      // Descriptor registers are FROZEN while a transfer is in flight.
      // Overwriting them mid-transfer corrupts it, and flipping dir re-routes
      // an in-flight write to the other port, where the address shim rejects
      // the now out-of-range address, never grants, and the FSM deadlocks.
      // STATUS (0x4) stays writable so done can be cleared at any time.
      if (cfg_wr && (!busy_o || cfg_off == 4'h4)) begin
        case (cfg_off)
          4'h0: reg_src_q    <= cfg_i.req.data;
          4'h1: reg_dstrow_q <= cfg_i.req.data;
          4'h2: reg_len_q    <= cfg_i.req.data;
          4'h3: begin
            reg_dir_q    <= cfg_i.req.data[1];
            reg_negate_q <= cfg_i.req.data[2];
            start_pulse  <= cfg_i.req.data[0] & ~busy_o;
          end
          default: ;  // STATUS is read-only apart from done-clear below
        endcase
      end
      if (cfg_rd) begin
        case (cfg_off)
          4'h0: cfg_rsp_q.data <= reg_src_q;
          4'h1: cfg_rsp_q.data <= reg_dstrow_q;
          4'h2: cfg_rsp_q.data <= reg_len_q;
          4'h3: cfg_rsp_q.data <= {29'b0, reg_negate_q, reg_dir_q, 1'b0};
          4'h4: cfg_rsp_q.data <= {30'b0, done_q, busy_o};
          default: cfg_rsp_q.data <= 32'hDEAD_BEEF;
        endcase
      end
    end
  end
  // ------------------------------------------------------------------------
  // Sequencer state
  // ------------------------------------------------------------------------
  typedef enum logic [1:0] {
    IDLE,
    RUN,
    DRAIN
  } state_e;

  state_e        state_q;

  // read-side (issue) counters
  logic   [15:0] rd_row_q;
  logic   [ 3:0] rd_bank_q;
  logic   [15:0] rd_widx_q;  // payload word index of the word being fetched
  logic   [31:0] rd_left_q;  // accesses still to issue
  // capture pipe: address is registered on read-gnt, joined with data on
  // rsp.valid (which is always exactly one cycle after gnt), then queued
  logic   [31:0] addr_pipe_q;
  // small elastic buffer between the read and write ports; DEPTH 4 is enough
  // to sustain one word per cycle across the 1-cycle read latency
  localparam int unsigned FIFO_DEPTH = 4;
  logic [31:0] fifo_addr_q[FIFO_DEPTH];
  logic [31:0] fifo_data_q[FIFO_DEPTH];
  logic [1:0] fifo_wp_q, fifo_rp_q;
  logic [2:0] fifo_cnt_q;
  logic [2:0] credits_q;  // free slots, counting words already in flight
  logic fifo_push, fifo_pop;

  logic [31:0] n_rows;
  logic [31:0] n_access;
  assign n_rows   = reg_len_q / PAYLOAD_PER_ROW;  // 8 payload words per row
  // Each intermediate row has one additional bank-8 access which duplicates
  // bank 0 of the following row. The final row has no successor, so its bank 8
  // is neither read nor written. This also removes the old one-word guard
  // requirement on the DMEM source/destination buffer.
  assign n_access = (n_rows == 0) ? 32'd0 : n_rows * BANKS_PER_ROW - 32'd1;

  assign busy_o   = (state_q != IDLE);
  assign done_o   = done_q;
  // ------------------------------------------------------------------------
  // Address generation - pure shifts, no divide, no modulo
  // ------------------------------------------------------------------------
  logic [31:0] src_addr;  // linear in DMEM
  logic [31:0] spm_addr;  // scattered into the 9-bank row layout
  assign src_addr = reg_src_q + {14'b0, rd_widx_q, 2'b00};
  assign spm_addr = SPM_BASE
                  + (((reg_dstrow_q + {16'b0, rd_row_q}) << ROW_SHIFT)
                     | ({28'b0, rd_bank_q} << BANK_SHIFT));
  // ------------------------------------------------------------------------
  // Throttle: optionally give the HCI port a cycle back
  // ------------------------------------------------------------------------
  logic [$clog2(DUTY > 0 ? DUTY : 2)-1:0] duty_q;
  logic                                   may_issue;
  generate
    if (DUTY > 0) begin : gen_throttle
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) duty_q <= '0;
        else if (dmem_o.rsp.gnt || spm_o.rsp.gnt)
          duty_q <= (duty_q == DUTY[$bits(duty_q)-1:0] - 1) ? '0 : duty_q + 1'b1;
      end
      assign may_issue = (duty_q != DUTY[$bits(duty_q)-1:0] - 1);
    end else begin : gen_no_throttle
      assign duty_q    = '0;
      assign may_issue = 1'b1;
    end
  endgenerate
  // ------------------------------------------------------------------------
  // Port muxing: dir 0 = load (DMEM -> SPM), dir 1 = store (SPM -> DMEM)
  // ------------------------------------------------------------------------
  req_t rd_req, wr_req;
  rsp_t rd_rsp, wr_rsp;
  always_comb begin
    if (!reg_dir_q) begin  // LOAD: read DMEM, write SPM
      dmem_o.req = rd_req;
      spm_o.req  = wr_req;
      rd_rsp     = dmem_o.rsp;
      wr_rsp     = spm_o.rsp;
    end else begin  // STORE: read SPM, write DMEM
      spm_o.req  = rd_req;
      dmem_o.req = wr_req;
      rd_rsp     = spm_o.rsp;
      wr_rsp     = dmem_o.rsp;
    end
  end
  // read request
  always_comb begin
    rd_req      = '{req: 1'b0, we: 1'b0, be: 4'b1111, addr: 32'b0, data: 32'b0};
    rd_req.req  = (state_q == RUN) && (rd_left_q != 0) && (credits_q != 0) && may_issue;
    rd_req.addr = reg_dir_q ? spm_addr : src_addr;
  end
  // write request - drains the head of the FIFO
  always_comb begin
    wr_req      = '{req: 1'b0, we: 1'b1, be: 4'b1111, addr: 32'b0, data: 32'b0};
    wr_req.req  = (fifo_cnt_q != 0);
    wr_req.addr = fifo_addr_q[fifo_rp_q];
    wr_req.data = fifo_data_q[fifo_rp_q];
  end

  assign fifo_push = rd_rsp.valid;
  assign fifo_pop  = wr_req.req && wr_rsp.gnt;
  // ------------------------------------------------------------------------
  // Main FSM
  // ------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q     <= IDLE;
      rd_row_q    <= '0;
      rd_bank_q   <= '0;
      rd_widx_q   <= '0;
      rd_left_q   <= '0;
      addr_pipe_q <= '0;
      fifo_wp_q   <= '0;
      fifo_rp_q   <= '0;
      fifo_cnt_q  <= '0;
      credits_q   <= FIFO_DEPTH[2:0];
      done_q      <= 1'b0;
    end else begin
      // done is sticky until the CPU clears it, or a new transfer starts
      if (cfg_wr && (cfg_off == 4'h4) && cfg_i.req.data[1]) done_q <= 1'b0;

      // --- FIFO bookkeeping, shared by all states ---
      if (fifo_push) begin
        fifo_addr_q[fifo_wp_q] <= addr_pipe_q;
        // Optional FP16 negate is a raw sign-bit toggle on each packed
        // 16-bit lane.  Apply it only while loading DMEM -> SPM; STORE
        // must preserve SPM data exactly.  Descriptor registers are frozen
        // while busy, so reg_negate_q/reg_dir_q are stable for the response.
        fifo_data_q[fifo_wp_q] <= (!reg_dir_q && reg_negate_q)
                                      ? (rd_rsp.data ^ 32'h8000_8000)
                                      : rd_rsp.data;
        fifo_wp_q <= fifo_wp_q + 1'b1;
      end
      if (fifo_pop) fifo_rp_q <= fifo_rp_q + 1'b1;
      unique case ({
        fifo_push, fifo_pop
      })
        2'b10:   fifo_cnt_q <= fifo_cnt_q + 1'b1;
        2'b01:   fifo_cnt_q <= fifo_cnt_q - 1'b1;
        default: ;
      endcase

      // a credit is spent when a read is granted and returned when the
      // corresponding write retires
      unique case ({
        rd_req.req && rd_rsp.gnt, fifo_pop
      })
        2'b10:   credits_q <= credits_q - 1'b1;
        2'b01:   credits_q <= credits_q + 1'b1;
        default: ;
      endcase

      unique case (state_q)
        IDLE: begin
          if (start_pulse && (reg_len_q != 0)) begin
            state_q   <= RUN;
            rd_row_q  <= '0;
            rd_bank_q <= '0;
            rd_widx_q <= '0;
            rd_left_q <= n_access;
            done_q    <= 1'b0;
          end
        end
        RUN: begin
          if (rd_req.req && rd_rsp.gnt) begin
            rd_left_q   <= rd_left_q - 1'b1;
            addr_pipe_q <= reg_dir_q ? src_addr : spm_addr;
            // the (row, bank) walk. rd_widx_q deliberately does NOT advance
            // across the bank 8 -> bank 0 wrap, because bank 8 of row r and
            // bank 0 of row r+1 hold the same payload word. On the final row,
            // rd_left_q reaches zero after bank 7, so bank 8 is never issued.
            if (rd_bank_q == BANK_LAST) begin
              rd_bank_q <= '0;
              rd_row_q  <= rd_row_q + 1'b1;
            end else begin
              rd_bank_q <= rd_bank_q + 1'b1;
              rd_widx_q <= rd_widx_q + 1'b1;
            end
          end
          if ((rd_left_q == 0) && (fifo_cnt_q == 0) && !rd_rsp.valid) state_q <= DRAIN;
        end

        DRAIN: begin
          state_q <= IDLE;
          done_q  <= 1'b1;
        end

        default: state_q <= IDLE;
      endcase
    end
  end
  // ------------------------------------------------------------------------
  // Assertions - cheap and they catch the two mistakes that actually happen
  // ------------------------------------------------------------------------
`ifndef SYNTHESIS
  // LEN must be a whole number of rows; spm_write() has the same requirement
  assert property (@(posedge clk_i) disable iff (!rst_ni)
      start_pulse |-> (reg_len_q[2:0] == 3'b000))
  else $error("isolde_spm_loader: LEN=%0d is not a multiple of 8", reg_len_q);
  // software must not touch the descriptor while a transfer is running - the
  // writes are ignored, but silently ignoring them hides a driver bug
  assert property (@(posedge clk_i) disable iff (!rst_ni) !(cfg_wr && busy_o && cfg_off != 4'h4))
  else $error("isolde_spm_loader: descriptor written while busy (reg 0x%0h)", cfg_off);
  // a request outstanding for a very long time means the far side never
  // granted - almost always an address outside the target address range
  int unsigned stall_ctr;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) stall_ctr <= 0;
    else if ((rd_req.req && !rd_rsp.gnt) || (wr_req.req && !wr_rsp.gnt)) stall_ctr <= stall_ctr + 1;
    else stall_ctr <= 0;
  end
  assert property (@(posedge clk_i) disable iff (!rst_ni) stall_ctr < 1000)
  else $error("isolde_spm_loader: no grant for 1000 cycles - address out of range?");
  // the elastic buffer must never overflow - credits guarantee it
  assert property (@(posedge clk_i) disable iff (!rst_ni)
      fifo_push |-> (fifo_cnt_q < FIFO_DEPTH[2:0]))
  else $error("isolde_spm_loader: FIFO overflow");
`endif

endmodule
