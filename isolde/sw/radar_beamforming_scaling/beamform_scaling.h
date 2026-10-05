/* SPDX-License-Identifier: Apache-2.0 */
#ifndef BEAMFORM_SCALING_H
#define BEAMFORM_SCALING_H

#include <stdint.h>
#include <bsp/onnx_redmule_runtime.h>

/* Same fixed ABI as radar_beamforming: split binary16, row-major
 * A[36][16], B[16][16], C[36][16]. No CPU floating point operations.
 * Header implementation keeps main.c the only firmware compilation unit.
 * The caller checks hardware tile availability and owns all six buffers.
 * Returns -1 without touching hardware for an invalid instance count.
 */
static inline int beamform_scaling(unsigned instances,
                                   const uint16_t *ar, const uint16_t *ai,
                                   const uint16_t *br, const uint16_t *bi,
                                   uint16_t *cr, uint16_t *ci)
{
  enum { BLOCKS = 3, A_COUNT = 12 * 16, B_COUNT = 16 * 16,
         C_COUNT = 12 * 16 };
  struct { uint32_t x, w, y; } spm[3];
  if (instances < 1u || instances > 3u) return -1;

  for (unsigned first = 0; first < BLOCKS; first += instances) {
    unsigned active = BLOCKS - first;
    if (active > instances) active = instances;
    uint32_t mask = (1u << active) - 1u;

    /* Launch every active tile before waiting. The final 2-instance batch
     * uses tile 0 only, and MUST NOT wait for an idle tile 1.
     */
    for (unsigned tile = 0; tile < active; ++tile) {
      unsigned offset = (first + tile) * A_COUNT;
      spm[tile].x = omrm_addr_start(tile, 0);
      spm[tile].w = omrm_upload_f16(tile, spm[tile].x, ar + offset, A_COUNT, 0);
      spm[tile].y = omrm_upload_f16(tile, spm[tile].w, br, B_COUNT, 0);
      omrm_zero_f16(tile, spm[tile].y, C_COUNT);
      omrm_gemm_f16_16_12_16(tile, spm[tile].x, spm[tile].w, spm[tile].y);
    }
    omrm_wait(mask);

    /* Cr = Ar Br + Ai (-Bi); keep Y between the two real GEMMs. */
    for (unsigned tile = 0; tile < active; ++tile) {
      omrm_upload_f16(tile, spm[tile].x, ai + (first + tile) * A_COUNT, A_COUNT, 0);
      omrm_upload_f16(tile, spm[tile].w, bi, B_COUNT, 1);
      omrm_gemm_f16_16_12_16(tile, spm[tile].x, spm[tile].w, spm[tile].y);
    }
    omrm_wait(mask);
    for (unsigned tile = 0; tile < active; ++tile)
      omrm_download_f16(tile, spm[tile].y, cr + (first + tile) * C_COUNT, C_COUNT);

    /* Ci = Ar Bi + Ai Br, using the same scratchpad accumulator. */
    for (unsigned tile = 0; tile < active; ++tile) {
      omrm_upload_f16(tile, spm[tile].x, ar + (first + tile) * A_COUNT, A_COUNT, 0);
      omrm_upload_f16(tile, spm[tile].w, bi, B_COUNT, 0);
      omrm_zero_f16(tile, spm[tile].y, C_COUNT);
      omrm_gemm_f16_16_12_16(tile, spm[tile].x, spm[tile].w, spm[tile].y);
    }
    omrm_wait(mask);
    for (unsigned tile = 0; tile < active; ++tile) {
      omrm_upload_f16(tile, spm[tile].x, ai + (first + tile) * A_COUNT, A_COUNT, 0);
      omrm_upload_f16(tile, spm[tile].w, br, B_COUNT, 0);
      omrm_gemm_f16_16_12_16(tile, spm[tile].x, spm[tile].w, spm[tile].y);
    }
    omrm_wait(mask);
    for (unsigned tile = 0; tile < active; ++tile)
      omrm_download_f16(tile, spm[tile].y, ci + (first + tile) * C_COUNT, C_COUNT);
  }
  return 0;
}
#endif
