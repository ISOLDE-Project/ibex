// Copyleft 2024

interface isolde_csr_if
import  isolde_hwe_cluster_pkg::*; 
();



    isolde_reg_data_t  tile_selection;  // Tile selection register      
    isolde_tile_csr_t  tile_intrerrupt_en;  // interrupt enable register 
    cluster_status_t cluster_status;
    // W1C strobe for the event barrier. The pending state lives in the
    // cluster (ungated clock) because the core clock is gated during WFI,
    // so the clear has to travel outwards.
    isolde_tile_csr_t  ip_clear;
    logic              ip_clear_en;
    
  // ------------------------


  // ==========================================================
  // Modports
  // ==========================================================

  modport cpu(
      
      output tile_selection,
      output tile_intrerrupt_en,
      output ip_clear,
      output ip_clear_en,
      input cluster_status

  );

  modport rf(
      
      input tile_selection ,
      input tile_intrerrupt_en,
      input ip_clear,
      input ip_clear_en,
      output cluster_status
  );

endinterface


