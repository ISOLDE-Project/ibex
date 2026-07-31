module isolde_tile
  import ibex_pkg::*;
  //import redmule_pkg::*;
  import isolde_tcdm_pkg::*;
  import aida_package::*;
#(

) (
    input logic clk_i,
    input logic rst_ni,
    input logic fetch_enable_i,

    // === evnets ===
    output logic                            [NC-1:0][1:0] evt_o,
    // === spm narrow interface ===
    isolde_tcdm_if.slave tcdm_spm_dma,

    // === cv_x_if interface ===
           isolde_cv_x_if.coproc_issue                    xif_issue_if_i,
           isolde_cv_x_if.coproc_result                   xif_result_if_o,
           isolde_cv_x_if.coproc_compressed               xif_compressed_if_i,
           isolde_cv_x_if.coproc_mem                      xif_mem_if_o

);

  /********************************************************/
  /**           Interface Definitions                   **/
  /*******************************************************/

  // ===  Memory banks  connections ===
  isolde_tcdm_pkg::req_t spm_req[N_TCDM_BANKS-1:0];
  isolde_tcdm_pkg::rsp_t spm_rsp[N_TCDM_BANKS-1:0];

  // === hardware accelerator  interconnect ===
  hci_core_intf #(.DW(HCI_DW)) redmule_hci (.clk(clk_i));

  /********************************************************/
  /**     TCDM                                           **/
  /*******************************************************/

  // === Memory banks ===
  generate
    for (genvar i = 0; i < N_TCDM_BANKS; i++) begin : gen_mem
      // Instantiate memory bank
      tcdm_mem_wrapper #() i_bank (
          .clk_i(clk_i),
          .rst_ni(rst_ni),
          .req_req(spm_req[i].req),
          .req_we(spm_req[i].we),
          .req_be(spm_req[i].be),
          .req_addr(spm_req[i].addr),
          .req_data(spm_req[i].data),
          .gnt(spm_rsp[i].gnt),
          .valid(spm_rsp[i].valid),
          .rsp_data(spm_rsp[i].data)
      );
    end
  endgenerate

  isolde_tcdm_interconnect #(
      .ALIGN (1'b0),
      .HCI_DW(HCI_DW)
  ) i_tcdm_interconnect (
      .clk_i,
      .rst_ni,
      .s_hci_core (redmule_hci),
      .s_tcdm_core(tcdm_spm_dma),
      .mem_req_o  (spm_req),
      .mem_rsp_i  (spm_rsp)
  );
  /********************************************************/
  /**     Hardware Engine HWE                            **/
  /*******************************************************/
  isolde_redmule_top #(
      .N_CORES  (NC),
      .DW       (HCI_DW),  // TCDM port dimension (in bits
      .AddrWidth(HCI_AW)
  ) i_redmule_top (
      .clk_i         (clk_i),
      .rst_ni        (rst_ni),
      .test_mode_i   (REDMULE_TEST_MODE),
      .fetch_enable_i(fetch_enable_i),
      .evt_o,
      .m_hci_core    (redmule_hci),
      .xif_issue_if_i,
      .xif_result_if_o,
      .xif_compressed_if_i,
      .xif_mem_if_o
  );

`ifdef TARGET_VERILATOR   
  isolde_hci_monitor #(
      .AW  (HCI_AW),
      .DW  (HCI_DW),
      .NAME("spm_hci_monitor")
  ) i_hci_monitor (
      .clk_i,
      .rst_ni,
      .hci_core(redmule_hci)
  );
`endif
endmodule
