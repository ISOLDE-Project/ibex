// Copyleft 2024

interface isolde_register_file_if #(
    parameter int unsigned NumReadPorts = 5
);
  import isolde_register_file_pkg::*;

  typedef struct packed {logic [RegAddrWidth-1:0] addr;} isolde_rf_addr_t;

  typedef struct packed {logic [RegSize-1:0][RegDataWidth-1:0] data;} isolde_rf_data_t;

  // ------------------------
  // Parameterized number of read ports
  // ------------------------

  isolde_rf_addr_t [NumReadPorts-1:0] raddr;
  isolde_rf_data_t [NumReadPorts-1:0] rdata;

  // ------------------------
  // Write port
  // ------------------------
  typedef struct packed {
    isolde_rf_addr_t addr;
    isolde_rf_data_t data;
    logic            we;
  } write_port_t;

  write_port_t wp;
  isolde_rf_data_t wp_echo;

  // ------------------------
  // Error
  // ------------------------
  logic isolde_rf_err;

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
      input wp_echo,
      input isolde_rf_err
  );

  modport rf(
      // Read ports
      input raddr,
      output rdata,
      // Write port
      input wp,
      // Misc
      output wp_echo,
      output isolde_rf_err
  );

endinterface


