// Copyleft ISOLDE 2025

/* this is inspired from the hci_interconnect.sv file from https://github.com/pulp-platform/hci.git
 * original authors:
 * Francesco Conti <f.conti@unibo.it>
 * Tobias Riedener <tobiasri@student.ethz.ch>
 *
 */

import isolde_soc_package::*;

module isolde_tcdm_interconnect #(
    parameter int unsigned N_HWPE = 1,  // Number of HWPEs attached to the port
    parameter int unsigned N_CORE = 1,  // Number of Core ports
    parameter int unsigned N_EXT = 1,  // Number of External ports
    parameter int unsigned N_MEM = 16,  // Number of Memory banks
    parameter int unsigned AWC     = isolde_soc_package::DEFAULT_AW  , // Address Width Core   (slave ports)
    parameter int unsigned AWM     = isolde_soc_package::DEFAULT_AW  , // Address width memory (master ports)
    parameter int unsigned DW_LIC  = isolde_soc_package::DEFAULT_DW  , // Data Width for Log Interconnect
    parameter int unsigned BW_LIC  = isolde_soc_package::DEFAULT_BW  , // Byte Width for Log Interconnect
    parameter int unsigned UW_LIC  = isolde_soc_package::DEFAULT_UW  , // User Width for Log Interconnect
    parameter int unsigned IW = N_HWPE + N_CORE + N_DMA + N_EXT,  // ID Width
    parameter int unsigned EXPFIFO = 0,  // FIFO Depth for HWPE Interconnect
    parameter int unsigned DWH     = isolde_soc_package::DEFAULT_DW  , // Data Width for HWPE Interconnect
    parameter int unsigned AWH     = isolde_soc_package::DEFAULT_AW  , // Address Width for HWPE Interconnect
    parameter int unsigned BWH     = isolde_soc_package::DEFAULT_BW  , // Byte Width for HWPE Interconnect
    parameter int unsigned WWH     = isolde_soc_package::DEFAULT_WW  , // Word Width for HWPE Interconnect
    parameter int unsigned OWH = AWH,  // Offset Width for HWPE Interconnect
    parameter int unsigned UWH = isolde_soc_package::DEFAULT_UW  // User Width for HWPE Interconnect
) (
    input logic               clk_i,
    input logic               rst_ni,
          hci_core_intf.slave cores [N_CORE-1:0],
          hci_core_intf.slave ext   [ N_EXT-1:0],
          hci_mem_intf.master mems  [ N_MEM-1:0],
          hci_core_intf.slave hwpe
);

  hci_core_intf #(.UW(UW_LIC)) all_except_hwpe[N_CORE+N_DMA+N_EXT-1:0] (.clk(clk_i));

  hci_mem_intf #(
      .IW(IW),
      .UW(UW_LIC)
  ) all_except_hwpe_mem[N_MEM-1:0] (
      .clk(clk_i)
  );

  hci_mem_intf #(
      .IW(IW),
      .UW(UW_LIC)
  ) hwpe_mem[N_MEM-1:0] (
      .clk(clk_i)
  );




  isolde_log_interconnect #(
      .N_SLAVES (N_CORE + N_EXT),
      .N_MASTERS(N_MEM)
  ) i_log_interconnect (
      .clk_i (clk_i),
      .rst_ni(rst_ni),
      .s_cores (all_except_hwpe),
      .m_mems  (all_except_hwpe_mem)
  );

  generate
    if (N_HWPE > 0) begin : hwpe_interconnect_gen

      hci_hwpe_interconnect #(
          .FIFO_DEPTH (EXPFIFO),
          .NB_OUT_CHAN(N_MEM),
          .AWM        (AWM),
          .DWH        (DWH),
          .AWH        (AWH),
          .BWH        (BWH),
          .WWH        (WWH),
          .OWH        (OWH),
          .UWH        (UWH)
      ) i_hwpe_interconnect (
          .clk_i  (clk_i),
          .rst_ni (rst_ni),
          .clear_i(clear_i),
          .in     (hwpe),
          .out    (hwpe_mem)
      );

      hci_shallow_interconnect #(
          .NB_CHAN(N_MEM)
      ) i_shallow_interconnect (
          .clk_i  (clk_i),
          .rst_ni (rst_ni),
          .clear_i(clear_i),
          .ctrl_i (ctrl_i),
          .in_high(all_except_hwpe_mem),
          .in_low (hwpe_mem),
          .out    (mems)
      );

    end else begin : no_hwpe_interconnect_gen

      for (genvar ii = 0; ii < N_MEM; ii++) begin : no_hwpe_mem_binding
        hci_mem_assign i_mem_assign (
            .tcdm_slave (all_except_hwpe_mem[ii]),
            .tcdm_master(mems[ii])
        );
      end

    end
  endgenerate

  generate
    for (genvar ii = 0; ii < N_CORE; ii++) begin : cores_binding
      hci_core_assign i_cores_assign (
          .tcdm_slave (cores[ii]),
          .tcdm_master(all_except_hwpe[ii])
      );
    end  // cores_binding
    for (genvar ii = 0; ii < N_EXT; ii++) begin : ext_binding
      hci_core_assign i_ext_assign (
          .tcdm_slave (ext[ii]),
          .tcdm_master(all_except_hwpe[N_CORE+ii])
      );
    end  // ext_binding
    for (genvar ii = 0; ii < N_DMA; ii++) begin : dma_binding
      hci_core_assign i_dma_assign (
          .tcdm_slave (dma[ii]),
          .tcdm_master(all_except_hwpe[N_CORE+N_EXT+ii])
      );
    end  // dma_binding
  endgenerate

endmodule  // hci_interconnect
