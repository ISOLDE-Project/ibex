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

#ifdef __cplusplus
}
#endif

#endif /* ONNX_REDMULE_RUNTIME_H */
