// Copyleft 2024

interface isolde_csr_if
//import  isolde_hwe_cluster_pkg::*;
 #(
  parameter int unsigned RegDataWidth = isolde_hwe_cluster_pkg::RegDataWidth,  // Default register data width
  parameter int unsigned TileCSRWidth = isolde_hwe_cluster_pkg::TileCSRWidth   // Default tile status & configuration register width

)
();


    logic [RegDataWidth-1:0] tile_selection;  // Tile selection register      
    logic [TileCSRWidth-1:0] tile_intr_en;  // interrupt enable register   
    logic [TileCSRWidth-1:0] tile_evt;  // tile event status   
  // ------------------------


  // ==========================================================
  // Modports
  // ==========================================================

  modport cpu(
      
      output tile_selection,
      output tile_intr_en,
      input tile_evt
  );

  modport rf(
      
      input tile_selection ,
      input tile_intr_en,
      output tile_evt
  );

endinterface


