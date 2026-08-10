// Copyleft 2024
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * ISOLDE additional register file
 *
 * Register file with  15x 4*32 bit wide registers. 
 * This register file is based on flip flops. Use this register file when
 * targeting FPGA synthesis or Verilator simulation.
 */

module isolde_register_file_ff
  import isolde_register_file_pkg::*;
#(
    parameter int unsigned NumReadPorts = 5
) (
    // Clock and Reset
    input logic clk_i,
    input logic rst_ni,

    // Register file interface (RF side)
    isolde_register_file_if.rf isolde_rf_bus
);

  // ------------------------------------------------------------
  // Internal register file:
  // RegCount registers, each RegSize x RegDataWidth bits
  // ------------------------------------------------------------
  logic [RegSize-1:0][RegDataWidth-1:0] reg_file[RegCount-1:0];

  // Error tracking
  logic isolde_rf_err_write;
  logic [NumReadPorts-1:0] isolde_rf_err_read;

  // ------------------------------------------------------------
  // Write process
  // ------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int i = 0; i < RegCount; i++) begin
        reg_file[i] <= '0;
      end
      isolde_rf_err_write <= 1'b0;
    end else begin
      isolde_rf_err_write <= 1'b0;

      if (isolde_rf_bus.wp.we) begin
        if (isolde_rf_bus.wp.addr < RegCount) begin
          reg_file[isolde_rf_bus.wp.addr] <= isolde_rf_bus.wp.data;
        end else begin
          isolde_rf_err_write <= 1'b1;
        end
      end
    end
  end

  // ------------------------------------------------------------
  // Write echo (combinational)
  // ------------------------------------------------------------
  always_comb begin
    isolde_rf_bus.wp_echo = '0;
    if (isolde_rf_bus.wp.we) begin
      isolde_rf_bus.wp_echo = isolde_rf_bus.wp.data;
    end
  end

  // ------------------------------------------------------------
  // Read ports (generate loop)
  // ------------------------------------------------------------
  genvar rp_i;
  generate
    for (rp_i = 0; rp_i < NumReadPorts; rp_i++) begin : gen_read_ports
      always_comb begin
        if (isolde_rf_bus.raddr[rp_i] < RegCount) begin
          isolde_rf_bus.rdata[rp_i] = reg_file[isolde_rf_bus.raddr[rp_i]];
          isolde_rf_err_read[rp_i]  = 1'b0;
        end else begin
          isolde_rf_bus.rdata[rp_i] = '0;
          isolde_rf_err_read[rp_i]  = 1'b1;
        end
      end
    end
  endgenerate

  // ------------------------------------------------------------
  // Combined error output
  // ------------------------------------------------------------
  //assign isolde_rf_bus.isolde_rf_err = isolde_rf_err_write | (|isolde_rf_err_read);

endmodule
