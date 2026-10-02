// Copyleft 2024

// Interface definition
interface isolde_x_register_file_if ();
import isolde_x_register_file_pkg::*;



  // ------------------------
  //  read ports
  // ------------------------
  isolde_x_rf_addr_t  raddr;
  isolde_x_rf_data_t  rdata;


  // Error detection
//   isolde_x_rf_err_t isolde_x_rf_err;  // invalid reads

  modport cpu(
      // Read ports
      output raddr,
      input rdata
      // Misc
      //input isolde_x_rf_err
  );

  modport rf(
      // Read ports
      input raddr,
      output rdata
      // Misc
      //output isolde_x_rf_err
  );


endinterface


module isolde_x_register_file_interconnect 
import isolde_x_register_file_pkg::*;
(
    isolde_x_register_file_if.cpu x_rf_bus,
    //decoder ports
    input isolde_x_rf_addr_t   raddr_i,
    //exec port
    output isolde_x_rf_addr_t  raddr_o,
    output isolde_x_rf_data_t  rdata_o
);
assign raddr_o=x_rf_bus.raddr;
assign rdata_o=x_rf_bus.rdata;

assign x_rf_bus.raddr= raddr_i;
endmodule