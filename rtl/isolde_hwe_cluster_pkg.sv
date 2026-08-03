// Copyright (c) ISOLDE 2026
// SPDX-License-Identifier: Apache-2.0

package isolde_hwe_cluster_pkg;

  // === do not edit ===
  parameter int unsigned CsrImmWidth  = 5;
  parameter int unsigned RegDataWidth = 32;

  // Default tile status & configuration register width
  parameter int unsigned TileCSRWidth = CsrImmWidth;

  parameter int unsigned N_HWE_TILES  = 2; //hardware engine(HWE) tiles
  // Useful derived constants
  parameter int unsigned ID_WIDTH = (N_HWE_TILES > 1) ? $clog2(N_HWE_TILES) : 1;
  parameter int unsigned RegByteWidth = RegDataWidth / 8;


  // Common typedefs
  typedef logic [RegDataWidth-1:0] isolde_reg_data_t;
  typedef logic [TileCSRWidth-1:0] isolde_tile_csr_t;

endpackage : isolde_hwe_cluster_pkg
