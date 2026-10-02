// Copyleft 2026 ISOLDE
//
// isolde_event_barrier
// --------------------
// Latches cluster completion events into a sticky pending vector that drives
// irq_software_i.
//
// Why this cannot live inside the core
// ------------------------------------
// ibex_top gates the core clock during WFI:
//
//     assign clock_en = (core_busy_q != IbexMuBiOff) | debug_req_i
//                     | irq_pending | irq_nm_i;
//
// so no flop inside the core can update while it sleeps - which is why
// ibex_cs_registers notes that mip must be "purely combinational ... to
// re-enable the clock upon WFI". CSR_ISOLDE_TILE_IP is in that gated domain
// and therefore cannot be used to hold the wakeup. This module runs on the
// ungated cluster clock instead.
//
// What it fixes
// -------------
// core_evt from the tiles is a single-cycle pulse. If a tile completes
// between the pending-bit test and the WFI in redmule_wait_all(), the pulse
// is gone before the core sleeps, irq_pending is 0, the clock gates, and the
// core sleeps forever holding a pending bit that says the work is done.
// Latching the event removes that race by construction, and gives pulse
// sources (tiles) and level sources (isolde_spm_loader done_o) identical
// software-visible behaviour.
//
// Semantics
// ---------
//   pending <= (pending & ~clear) | evt
//
// Set wins over clear, so an event arriving in the same cycle as a W1C is
// never lost. This is the same merge order ibex_cs_registers already used for
// tile_ip. Note the consequence for LEVEL sources: while evt_i is still
// asserted the bit re-arms immediately, so software must clear the source
// (e.g. SPMLD_STATUS.done) before clearing the pending bit.
//
module isolde_event_barrier #(
    parameter int unsigned W = 1
) (
    input  logic         clk_i,   // ungated cluster clock
    input  logic         rst_ni,
    input  logic [W-1:0] evt_i,   // pulses or levels, mixed
    input  logic [W-1:0] clear_i, // W1C strobe, already qualified by enable
    output logic [W-1:0] pending_o
);

  logic [W-1:0] pending_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) pending_q <= '0;
    else         pending_q <= (pending_q & ~clear_i) | evt_i;
  end

  assign pending_o = pending_q;

endmodule
