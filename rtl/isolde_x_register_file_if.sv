// Copyleft 2024

// Interface definition
interface isolde_x_register_file_if #(
    parameter int unsigned RegDataWidth = 32,  // Default register data width
    parameter int unsigned RegAddrWidth = 5,   // Default register address width
    parameter int unsigned NumReadPorts = 4
);

  typedef logic [RegAddrWidth-1:0] isolde_x_rf_addr_t;
  typedef logic [RegDataWidth-1:0] isolde_x_rf_data_t;

  // ------------------------
  // Parameterized number of read ports
  // ------------------------
  isolde_x_rf_addr_t [NumReadPorts-1:0] raddr;
  isolde_x_rf_data_t [NumReadPorts-1:0] rdata;


  // Error detection
  logic [NumReadPorts-1:0] isolde_x_rf_err;  // invalid reads

  modport cpu(
      // Read ports
      output raddr,
      input rdata,
      // Misc
      input isolde_x_rf_err
  );

  modport rf(
      // Read ports
      input raddr,
      output rdata,
      // Misc
      output isolde_x_rf_err
  );

endinterface


