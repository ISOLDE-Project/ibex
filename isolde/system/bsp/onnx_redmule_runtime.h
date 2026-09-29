/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * Runtime ABI used by the ONNX-MLIR AISMEM -> LLVM RedMulE lowering.
 */

#ifndef ONNX_REDMULE_RUNTIME_H
#define ONNX_REDMULE_RUNTIME_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

uint32_t omrm_addr_start(uint32_t tile, uint32_t bank);

uint32_t omrm_upload_f16(uint32_t tile, uint32_t spm_addr,
                         const void *source, uint32_t elements,
                         uint32_t negate);

void omrm_zero_f16(uint32_t tile, uint32_t spm_addr, uint32_t elements);

/* MVP instruction specialization used by complex_gemm_12x16x16.onnx. */
void omrm_gemm_f16_16_12_16(uint32_t tile, uint32_t x_spm_addr,
                            uint32_t w_spm_addr, uint32_t y_spm_addr);

void omrm_wait(uint32_t mask);

void omrm_download_f16(uint32_t tile, uint32_t spm_addr, void *destination,
                       uint32_t elements);

/*
 * Upload a transformed 2-D window of a row-major FP16 matrix (leading
 * dimension src_ld) into a zero-padded dst_rows x dst_cols SPM matrix:
 *
 *   win  = source[row_offset : row_offset + rows, col_offset : col_offset + cols]
 *   win' = (flags & OMRM_TILE_TRANSPOSE) ? win^T : win
 *   dst[i][j] = f(win'[i][j]) inside win', +0.0 outside
 *   f: OMRM_TILE_RELU clears negative values (sign-bit test),
 *      OMRM_TILE_NEGATE flips the sign bit.
 *
 * Raw binary16 bit operations only.  dst_cols must be 16 and
 * dst_rows * 16 <= OMRM_TILE_MAX_ELEMENTS.  Returns the next SPM address,
 * like omrm_upload_f16.  Emitted for aismem.RedMulEUploadTile.
 */
#define OMRM_TILE_TRANSPOSE     1u
#define OMRM_TILE_RELU          2u
#define OMRM_TILE_NEGATE        4u
#define OMRM_TILE_MAX_ELEMENTS  256u

uint32_t omrm_upload_tile_f16(uint32_t tile, uint32_t spm_addr,
                              const void *source, uint32_t src_ld,
                              uint32_t row_offset, uint32_t col_offset,
                              uint32_t rows, uint32_t cols,
                              uint32_t dst_rows, uint32_t dst_cols,
                              uint32_t flags);					   

#ifdef __cplusplus
}
#endif

#endif /* ONNX_REDMULE_RUNTIME_H */
