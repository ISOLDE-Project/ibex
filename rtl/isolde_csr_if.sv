// Copyleft 2024

interface isolde_csr_if #(
  parameter int unsigned RegDataWidth = 32  // Default register data width
)
();


    logic [RegDataWidth-1:0] tile_selection;  // Tile selection register      

  // ------------------------


  // ==========================================================
  // Modports
  // ==========================================================

  modport cpu(
      
      output tile_selection
  );

  modport rf(
      
      input tile_selection  
  );

endinterface


