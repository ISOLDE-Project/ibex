// ============================================================================
// Module: ibex_rst
// Description:
//   After reset (rst_ni == 1), waits for 10 clock cycles,
//   then asserts fetch_enable_o = 1 permanently.
//
// Technology: Xilinx Vivado (synthesizable SystemVerilog)
// Author: ChatGPT
// ============================================================================

module ibex_rst (
    input  logic clk_i,           // clock input
    input  logic rst_ni,          // active-low asynchronous reset
    output logic fetch_enable_o   // fetch enable output
);

  // --------------------------------------------------------------------------
  // Parameters
  // --------------------------------------------------------------------------
  localparam int unsigned DELAY_CYCLES   = 10;
  localparam int unsigned COUNTER_WIDTH  = $clog2(DELAY_CYCLES + 1);

  // --------------------------------------------------------------------------
  // Internal signals
  // --------------------------------------------------------------------------
  logic [COUNTER_WIDTH-1:0] counter_q;
  logic                     fetch_enable_q;

  // --------------------------------------------------------------------------
  // Sequential logic
  // --------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      counter_q       <= '0;
      fetch_enable_q  <= 1'b0;
    end else begin
      if (!fetch_enable_q) begin
        if (counter_q == DELAY_CYCLES - 1) begin
          fetch_enable_q <= 1'b1;
        end else begin
          counter_q <= counter_q + 1'b1;
        end
      end
    end
  end

  // --------------------------------------------------------------------------
  // Output assignment
  // --------------------------------------------------------------------------
  assign fetch_enable_o = fetch_enable_q;

endmodule
