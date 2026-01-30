package isolde_register_file_pkg;

  parameter int unsigned RegDataWidth = 32;  // Width of each data element (default is 32 bits)
  parameter int unsigned RegCount = 15;  // Number of registers (default is 15)
  parameter int unsigned RegSize = 4;  // Number of data words per register (4 words per register)
  parameter int unsigned NumReadPorts = 5;  // Number of read ports
  //
  parameter int unsigned RegAddrWidth = $clog2(
      RegCount
  );  // Address width, automatically calculated

  // ------------------------
  // Read port types
  // ------------------------
  typedef logic [NumReadPorts-1:0][RegAddrWidth-1:0] isolde_rf_raddr_t;

  typedef logic [NumReadPorts-1:0][RegSize-1:0][RegDataWidth-1:0] isolde_rf_rdata_t;




  // ------------------------
  // Write port type
  // ------------------------
    typedef logic [RegAddrWidth-1:0] isolde_rf_waddr_t;

  typedef logic [RegSize-1:0][RegDataWidth-1:0] isolde_rf_wdata_t;

  typedef struct packed {
    isolde_rf_waddr_t addr;
    isolde_rf_wdata_t data;
    logic            we;
  } write_port_t;
endpackage
