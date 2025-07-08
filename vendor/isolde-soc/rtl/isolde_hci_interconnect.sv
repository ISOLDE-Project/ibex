// Copyleft ISOLDE 2025

/* 
 *
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
    isolde_tcdm_if.slave s_core,
    isolde_tcdm_if.master m_mems[N_TCDM_BANKS-1:0]

);

  isolde_tcdm_pkg::req_t cores_req[N_TCDM_BANKS:0];
  isolde_tcdm_pkg::rsp_t cores_rsp[N_TCDM_BANKS:0];
  //
  isolde_tcdm_pkg::req_t mems_req[N_TCDM_BANKS-1:0];
  isolde_tcdm_pkg::rsp_t mems_rsp[N_TCDM_BANKS-1:0];

  logic [N_MEM-1:0]       tcdm_gnt;
  logic [N_MEM-1:0][31:0] tcdm_r_data;
  logic [N_MEM-1:0]       tcdm_r_valid;


  for (genvar ii = 0; ii < N_TCDM_BANKS; ii++) begin : tcdm_binding

    ///
    assign cores_req[ii].req  = s_hci_core.req;
    assign cores_req[ii].addr = s_hci_core.add + ii * 4;
    assign cores_req[ii].we   = ~s_hci_core.wen;
    assign cores_req[ii].be   = s_hci_core.be[(ii+1)*4-1:ii*4];
    assign cores_req[ii].data = s_hci_core.data[(ii+1)*32-1:ii*32];
    ///
    assign m_tcdm[ii].req               = s_hci_core.req;
    assign m_tcdm[ii].add               = s_hci_core.add + ii * 4;
    assign m_tcdm[ii].wen               = s_hci_core.wen;
    assign m_tcdm[ii].be                = s_hci_core.be[(ii+1)*4-1:ii*4];
    assign m_tcdm[ii].data              = s_hci_core.data[(ii+1)*32-1:ii*32];
    assign tcdm_gnt[ii]                 = m_tcdm[ii].gnt;
    assign tcdm_r_valid[ii]             = m_tcdm[ii].r_valid;
    assign tcdm_r_data[ii]              = m_tcdm[ii].r_data;
  end

  assign s_hci_core.gnt = &tcdm_gnt;
  assign s_hci_core.r_data = {tcdm_r_data};
  assign s_hci_core.r_valid = &tcdm_r_valid;
  assign s_hci_core.r_opc = '0;
  assign s_hci_core.r_user = '0;
  //



  isolde_log_interconnect #(
      .N_SLAVES (N_MEM+EXT_PORTS),
      .N_MASTERS(N_MEM+EXT_PORTS)
  ) i_log_interconnect (
      .clk_i,
      .rst_ni,
      .s_cores(m_internal_mems),
      .m_mems (m_mems)
  );
endmodule
