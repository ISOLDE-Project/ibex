// Copyleft ISOLDE 2025

/* 
 * this is inspired from Heterogeneous Cluster Interconnect (HCI), https://github.com/pulp-platform/hci
 * 
 */

module isolde_hci_interconnect #(
    parameter int unsigned HCI_DW = 288,  // Data width of hci interface
    //
    parameter int unsigned N_TCDM_BANKS = HCI_DW / 32  // Number of Memory banks
) (
    input logic clk_i,  // Clock input, positive edge triggered
    input logic rst_ni,  // Asynchronous reset, active low
    hci_core_intf.slave s_hci_core,
    isolde_tcdm_if.slave s_tcdm_core,
    isolde_tcdm_if.master m_tcdm_mems[N_TCDM_BANKS-1:0]

);

  isolde_tcdm_pkg::req_t                          cores_req    [  N_TCDM_BANKS:0];
  isolde_tcdm_pkg::rsp_t                          cores_rsp    [  N_TCDM_BANKS:0];
  //
  isolde_tcdm_pkg::req_t                          mems_req     [N_TCDM_BANKS-1:0];
  isolde_tcdm_pkg::rsp_t                          mems_rsp     [N_TCDM_BANKS-1:0];

  logic                  [N_TCDM_BANKS-1:0]       tcdm_gnt;
  logic                  [N_TCDM_BANKS-1:0][31:0] tcdm_r_data;
  logic                  [N_TCDM_BANKS-1:0]       tcdm_r_valid;


  // === HCI binding ===
  for (genvar ii = 0; ii < N_TCDM_BANKS + 1; ii++) begin : hci_binding

    ///
    assign cores_req[ii].req  = s_hci_core.req;
    assign cores_req[ii].addr = s_hci_core.add + ii * 4;
    assign cores_req[ii].we   = ~s_hci_core.wen;
    assign cores_req[ii].be   = s_hci_core.be[(ii+1)*4-1:ii*4];
    assign cores_req[ii].data = s_hci_core.data[(ii+1)*32-1:ii*32];
    ///
    assign tcdm_gnt[ii]       = mems_rsp[ii].gnt;
    assign tcdm_r_valid[ii]   = mems_rsp[ii].valid;
    assign tcdm_r_data[ii]    = mems_rsp[ii].data;

  end

  assign s_hci_core.gnt = &tcdm_gnt;
  assign s_hci_core.r_data = {tcdm_r_data};
  assign s_hci_core.r_valid = &tcdm_r_valid;
  assign s_hci_core.r_opc = '0;
  assign s_hci_core.r_user = '0;
  //
  assign cores_req[N_TCDM_BANKS] = s_tcdm_core.req;
  assign s_tcdm_core.rsp = cores_rsp[N_TCDM_BANKS];

  // === TCDM banks binding ===

  for (genvar i = 0; i < N_TCDM_BANKS; i++) begin : gen_tcdm_banks
    assign m_tcdm_mems[i].req = mems_req[i];
    assign mems_rsp[i] = m_tcdm_mems[i].rsp;
  end

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
