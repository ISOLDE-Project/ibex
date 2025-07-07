// Copyleft ISOLDE 2025

/* 
 *
 * 
 */

module isolde_hci_interconnect #(
    parameter int unsigned HCI_DW = 288,  // Data width of hci interface
    parameter int unsigned EXT_PORTS = 1,  // Number of external ports
    //
    parameter int unsigned N_MEM = HCI_DW / 32  // Number of Memory banks
) (
    input logic clk_i,  // Clock input, positive edge triggered
    input logic rst_ni,  // Asynchronous reset, active low
    hci_core_intf.slave s_hci_core,
    hwpe_stream_intf_tcdm.master m_tcdm[N_MEM-1:0],

    isolde_tcdm_if.master m_mems[N_MEM+EXT_PORTS-1:0]

);
  logic [N_MEM-1:0]       tcdm_gnt;
  logic [N_MEM-1:0][31:0] tcdm_r_data;
  logic [N_MEM-1:0]       tcdm_r_valid;

  isolde_tcdm_if m_internal_mems[N_MEM+EXT_PORTS-1:0] ();
  for (genvar ii = 0; ii < N_MEM; ii++) begin : tcdm_binding

    ///
    assign m_internal_mems[ii].req.req  = s_hci_core.req;
    assign m_internal_mems[ii].req.addr = s_hci_core.add + ii * 4;
    assign m_internal_mems[ii].req.we   = ~s_hci_core.wen;
    assign m_internal_mems[ii].req.be   = s_hci_core.be[(ii+1)*4-1:ii*4];
    assign m_internal_mems[ii].req.data = s_hci_core.data[(ii+1)*32-1:ii*32];
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
