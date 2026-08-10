// Copyleft 2024

interface isolde_register_file_if ();
  import isolde_register_file_pkg::*;



  // ------------------------
  //  read ports
  // ------------------------

  isolde_rf_raddr_t raddr;
  isolde_rf_rdata_t rdata;



  write_port_t wp;
  isolde_rf_wdata_t wp_echo;

  // ------------------------
  // Error
  // ------------------------
  // logic isolde_rf_err;

  // ==========================================================
  // Modports
  // ==========================================================

  modport cpu(
      // Read ports
      output raddr,
      input rdata,
      // Write port
      output wp,
      // Misc
      input wp_echo
      // input isolde_rf_err
  );

  modport rf(
      // Read ports
      input raddr,
      output rdata,
      // Write port
      input wp,
      // Misc
      output wp_echo
      // output isolde_rf_err
  );

endinterface

module isolde_register_file_interconnect
  import isolde_register_file_pkg::*;
(
    isolde_register_file_if.cpu isolde_rf_if,
    input isolde_rf_raddr_t raddr_i,
    output isolde_rf_rdata_t rdata_o,
    input write_port_t wp_i,
    output isolde_rf_waddr_t waddr_o,
    output isolde_rf_wdata_t wp_echo_o

);
  assign isolde_rf_if.raddr = raddr_i;
  assign rdata_o = isolde_rf_if.rdata;
  assign waddr_o = wp_i.addr;
  assign wp_echo_o = isolde_rf_if.wp_echo;
  assign isolde_rf_if.wp = wp_i;
  
endmodule

