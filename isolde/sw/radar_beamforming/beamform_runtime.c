/* SPDX-License-Identifier: Apache-2.0 */
#include "beamform_runtime.h"
#include <bsp/onnx_redmule_runtime.h>

enum { TILES = 3, A_ELEMENTS = 12 * 16, B_ELEMENTS = 16 * 16,
       C_ELEMENTS = 12 * 16, TILE_MASK = 0x7 };
typedef struct { uint32_t x, w, y; } layout_t;

void beamform_runtime3(const uint16_t *ar, const uint16_t *ai,
                       const uint16_t *br, const uint16_t *bi,
                       uint16_t *cr, uint16_t *ci)
{
  layout_t spm[TILES];
  uint32_t tile;

  /* Wave 1: every tile owns a different 12-angle block; Y = Ar Br. */
  for (tile = 0; tile < TILES; ++tile) {
    spm[tile].x = omrm_addr_start(tile, 0);
    spm[tile].w = omrm_upload_f16(tile, spm[tile].x,
                                 ar + tile * A_ELEMENTS, A_ELEMENTS, 0);
    spm[tile].y = omrm_upload_f16(tile, spm[tile].w, br, B_ELEMENTS, 0);
    omrm_zero_f16(tile, spm[tile].y, C_ELEMENTS);
    omrm_gemm_f16_16_12_16(tile, spm[tile].x, spm[tile].w, spm[tile].y);
  }
  omrm_wait(TILE_MASK);

  /* Wave 2: Y += Ai (-Bi). Do not zero the accumulator here. */
  for (tile = 0; tile < TILES; ++tile) {
    omrm_upload_f16(tile, spm[tile].x, ai + tile * A_ELEMENTS, A_ELEMENTS, 0);
    omrm_upload_f16(tile, spm[tile].w, bi, B_ELEMENTS, 1);
    omrm_gemm_f16_16_12_16(tile, spm[tile].x, spm[tile].w, spm[tile].y);
  }
  omrm_wait(TILE_MASK);
  for (tile = 0; tile < TILES; ++tile)
    omrm_download_f16(tile, spm[tile].y, cr + tile * C_ELEMENTS, C_ELEMENTS);

  /* Wave 3: real outputs are saved, so Y can be reset for Ci = Ar Bi. */
  for (tile = 0; tile < TILES; ++tile) {
    omrm_upload_f16(tile, spm[tile].x, ar + tile * A_ELEMENTS, A_ELEMENTS, 0);
    omrm_upload_f16(tile, spm[tile].w, bi, B_ELEMENTS, 0);
    omrm_zero_f16(tile, spm[tile].y, C_ELEMENTS);
    omrm_gemm_f16_16_12_16(tile, spm[tile].x, spm[tile].w, spm[tile].y);
  }
  omrm_wait(TILE_MASK);

  /* Wave 4: Ci += Ai Br; preserve Y until all three tiles have finished. */
  for (tile = 0; tile < TILES; ++tile) {
    omrm_upload_f16(tile, spm[tile].x, ai + tile * A_ELEMENTS, A_ELEMENTS, 0);
    omrm_upload_f16(tile, spm[tile].w, br, B_ELEMENTS, 0);
    omrm_gemm_f16_16_12_16(tile, spm[tile].x, spm[tile].w, spm[tile].y);
  }
  omrm_wait(TILE_MASK);
  for (tile = 0; tile < TILES; ++tile)
    omrm_download_f16(tile, spm[tile].y, ci + tile * C_ELEMENTS, C_ELEMENTS);
}
