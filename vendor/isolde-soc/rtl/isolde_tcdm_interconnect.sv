// Copyleft ISOLDE 2025

/*
 * Inspired by Heterogeneous Cluster Interconnect (HCI)
 * See: https://github.com/pulp-platform/hci
 * 
 * The core master connected to s_tcdm_core has higher prio over the hardware engine(hwe)
 */

module isolde_tcdm_interconnect #(
    parameter int unsigned HCI_DW = 288,  // Data width of hci interface
    //
    parameter int unsigned N_TCDM_BANKS = HCI_DW / 32  // Number of Memory banks
) (
    input logic clk_i,  // Clock input, positive edge triggered
    input logic rst_ni,  // Asynchronous reset, active low
    hci_core_intf.slave s_hci_core,  // hwe slave interface
    isolde_tcdm_if.slave s_tcdm_core,  // core slave interface, higher prio
    isolde_tcdm_if.master m_tcdm_mems[N_TCDM_BANKS-1:0]  // memory bank masters

);

  isolde_tcdm_pkg::req_t cores_req[  N_TCDM_BANKS:0];  // One extra for s_tcdm_core
  isolde_tcdm_pkg::rsp_t cores_rsp[  N_TCDM_BANKS:0];
  //
  isolde_tcdm_pkg::req_t mems_req [N_TCDM_BANKS-1:0];
  isolde_tcdm_pkg::rsp_t mems_rsp [N_TCDM_BANKS-1:0];



  // === TCDM banks binding ===

  for (genvar i = 0; i < N_TCDM_BANKS; i++) begin : gen_tcdm_banks
    assign m_tcdm_mems[i].req = mems_req[i];
    assign mems_rsp[i] = m_tcdm_mems[i].rsp;
  end

  isolde_hci_interconnect #(
      .HCI_DW
  ) i_hci_interconnect (
      .clk_i,
      .rst_ni,
      .s_hci_core,
      .s_tcdm_core,
      .mem_req_o(cores_req),
      .mem_rsp_i(cores_rsp)
  );

  isolde_log_interconnect #(
      .N_SLAVES (N_TCDM_BANKS + 1),
      .N_MASTERS(N_TCDM_BANKS)
  ) i_log_interconnect (
      .clk_i,
      .rst_ni,
      .cores_req_i(cores_req),
      .cores_rsp_o(cores_rsp),
      .mems_req_o (mems_req),
      .mems_rsp_i (mems_rsp)
  );

endmodule
