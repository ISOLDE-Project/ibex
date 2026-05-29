// Copyleft 2024

// Interface definition
package isolde_x_register_file_pkg;
    parameter int unsigned RegDataWidth = 32;  // Default register data width
    parameter int unsigned RegAddrWidth = 5;  // Default register address width
    parameter int unsigned NumReadPorts = 4;


  typedef logic [NumReadPorts-1:0][RegAddrWidth-1:0] isolde_x_rf_addr_t;
  typedef logic [NumReadPorts-1:0][RegDataWidth-1:0] isolde_x_rf_data_t;
  typedef logic [NumReadPorts-1:0] isolde_x_rf_err_t;  // invalid reads

endpackage


