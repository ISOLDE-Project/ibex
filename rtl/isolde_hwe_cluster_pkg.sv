// Copyright (c) ISOLDE 2026
// SPDX-License-Identifier: Apache-2.0

package isolde_hwe_cluster_pkg;

  // === do not edit ===
  // parameter int unsigned CsrImmWidth  = 5;
  parameter int unsigned RegDataWidth = 32;


  parameter int unsigned N_HWE_TILES  = 2; //hardware engine(HWE) tiles
  
  parameter int unsigned ID_WIDTH = (N_HWE_TILES > 1) ? $clog2(N_HWE_TILES) : 1;
  parameter int unsigned CSR_WIDTH = N_HWE_TILES +1 ;
  //parameter int unsigned RegByteWidth = RegDataWidth / 8;

  // === spm narrow port start ====
  localparam int unsigned SPM_NARROW_ADDR_BASE = 32'h8000_1000;
  localparam int unsigned SPM_NARROW_SIZE = 32'h0000_1000;  //4kB

  // Common typedefs
  typedef logic [RegDataWidth-1:0] isolde_reg_data_t;
  typedef logic [CSR_WIDTH-1:0] isolde_tile_csr_t; //one extra global bit
  typedef logic [ID_WIDTH-1:0] isolde_tile_cnt_t; //one extra global bit

endpackage : isolde_hwe_cluster_pkg
