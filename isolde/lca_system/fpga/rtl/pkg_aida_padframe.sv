// Copyleft ISOLDE
package pkg_aida_padframe;

  //Structs for all_pads

  //Static connections signals
   typedef struct packed {
  
      logic        jtag_tdo;
     } pad_domain_all_pads_static_connection_signals_soc2pad_t;

   typedef struct packed {
      logic        jtag_tck;
      logic        jtag_tdi;
      logic        jtag_tms;
      logic        jtag_trstn;
     } pad_domain_all_pads_static_connection_signals_pad2soc_t;

  

  //Toplevel structs

  typedef struct packed {
    pad_domain_all_pads_static_connection_signals_pad2soc_t all_pads;
  } static_connection_signals_pad2soc_t;

  typedef struct packed {
    pad_domain_all_pads_static_connection_signals_soc2pad_t all_pads;
  } static_connection_signals_soc2pad_t;




endpackage : pkg_aida_padframe