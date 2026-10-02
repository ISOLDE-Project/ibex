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

void omrm_zero_f16(uint32_t tile, uint32_t spm_addr, uint32_t elements);

/*
 * In-SPM transforms for SPM-resident activations (aismem.SPMRelu,
 * aismem.SPMTranspose, aismem.SPMCopy).  They work on one tile through the
 * narrow SPM window with raw binary16 bit operations and keep bank 8 of each
 * row (the first word of the next row) consistent.  Addresses are row starts
 * (multiples of 64); a row holds 16 binary16 values.  The loader must be idle.
 */
void omrm_spm_relu_f16(uint32_t tile, uint32_t spm_addr, uint32_t rows);

/* dst[i][j] = j < rows ? src[j][i] : +0.0 for i < dst_rows (<= 16). */
void omrm_spm_transpose_f16(uint32_t tile, uint32_t src_addr,
                            uint32_t dst_addr, uint32_t rows,
                            uint32_t dst_rows);

void omrm_spm_copy_f16(uint32_t tile, uint32_t src_addr, uint32_t dst_addr,
                       uint32_t rows);

/*
 * Move `rows` (<= 16) SPM rows from one tile to another.  The RedMulE tiles
 * have no SPM-to-SPM path, so this is omrm_download_f16 from src_tile into a
 * data-memory staging buffer, then omrm_upload_tile_f16 into dst_tile as a
 * dst_rows x 16 matrix, zero padded; flags as for omrm_upload_tile_f16
 * (OMRM_TILE_TRANSPOSE writes the 16 x rows transpose).  src_tile must be
 * idle (waited).  Emitted for aismem.SPMMoveTile.
 */
void omrm_spm_move_f16(uint32_t src_tile, uint32_t src_addr,
                       uint32_t dst_tile, uint32_t dst_addr, uint32_t rows,
                       uint32_t dst_rows, uint32_t flags);

/* MVP instruction specialization used by complex_gemm_12x16x16.onnx. */
void omrm_gemm_f16_16_12_16(uint32_t tile, uint32_t x_spm_addr,
                            uint32_t w_spm_addr, uint32_t y_spm_addr);

void omrm_wait(uint32_t mask);

void omrm_download_f16(uint32_t tile, uint32_t spm_addr, void *destination,
                       uint32_t elements);

/*
 * Download the top-left rows x cols corner (rows <= 16, 1 <= cols <= 16) of
 * the SPM rows at spm_addr into a row-major destination with leading
 * dimension dst_ld (fp16 elements): SPM row r, columns 0..cols-1, go to
 * destination[r * dst_ld + 0 .. cols-1]; nothing else is written.  For one
 * 16-column N-tile of a wider result (cols = 16, dst_ld = N) and for partial
 * tiles (e.g. row 0, columns 0..3 of a [1, 4] classifier head).  Emitted for
 * aismem.RedMulEDownload unless the copy is contiguous whole rows.
 */
void omrm_download_tile_f16(uint32_t tile, uint32_t spm_addr,
                            void *destination, uint32_t dst_ld,
                            uint32_t rows, uint32_t cols);

#ifdef __cplusplus
}
#endif

#endif /* ONNX_REDMULE_RUNTIME_H */
