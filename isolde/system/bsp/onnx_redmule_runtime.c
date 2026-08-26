/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * Bare-metal RedMulE runtime used by generated ONNX-MLIR objects.
 * FP16 values are always copied as raw storage bits: RV32 performs no scalar
 * half-precision arithmetic in this file.
 */

#include <stdint.h>

#include <bsp/omp_redmule.h>
#include <bsp/onnx_redmule_runtime.h>
#include <bsp/spm.h>

#define OMRM_FP16_PER_ROW 16u
#define OMRM_PAYLOAD_WORDS 8u
#define OMRM_GUARD_FP16 2u

typedef uint16_t omrm_fp16_storage_t __attribute__((may_alias));

/* spm_write/spm_read touch one guard word beyond the eight payload words. */
static omrm_fp16_storage_t omrm_spm_row[OMRM_FP16_PER_ROW + OMRM_GUARD_FP16]
    __attribute__((aligned(4)));

static void omrm_require_complete_rows(uint32_t elements)
{
  if ((elements % OMRM_FP16_PER_ROW) != 0u) {
    _Exit(0x0bad0010);
  }
}

static void omrm_clear_guard(void)
{
  omrm_spm_row[OMRM_FP16_PER_ROW] = 0u;
  omrm_spm_row[OMRM_FP16_PER_ROW + 1u] = 0u;
}

uint32_t omrm_addr_start(uint32_t tile, uint32_t bank)
{
  if (tile >= isolde_get_tile_cnt()) {
    _Exit(0x0bad0002);
  }

  /* Remove stale completion state before this tile receives new work. */
  isolde_clear_tile_ip(REDMULE_BIT(tile));
  isolde_set_tile(tile);
  return get_addr_start(bank);
}

uint32_t omrm_upload_f16(uint32_t tile, uint32_t spm_addr,
                         const void *source, uint32_t elements,
                         uint32_t negate)
{
  const omrm_fp16_storage_t *src =
      (const omrm_fp16_storage_t *)source;
  uint32_t base;

  omrm_require_complete_rows(elements);
  isolde_set_tile(tile);

  for (base = 0u; base < elements; base += OMRM_FP16_PER_ROW) {
    uint32_t lane;
    for (lane = 0u; lane < OMRM_FP16_PER_ROW; ++lane) {
      uint16_t bits = src[base + lane];
      if (negate != 0u) {
        bits = (uint16_t)(bits ^ 0x8000u);
      }
      omrm_spm_row[lane] = bits;
    }
    omrm_clear_guard();
    spm_addr = spm_write(spm_addr, (uint32_t *)(void *)omrm_spm_row,
                         OMRM_PAYLOAD_WORDS);
  }

  return spm_addr;
}

void omrm_zero_f16(uint32_t tile, uint32_t spm_addr, uint32_t elements)
{
  uint32_t base;
  uint32_t lane;

  omrm_require_complete_rows(elements);
  isolde_set_tile(tile);

  for (lane = 0u; lane < OMRM_FP16_PER_ROW; ++lane) {
    omrm_spm_row[lane] = 0u;
  }
  omrm_clear_guard();

  for (base = 0u; base < elements; base += OMRM_FP16_PER_ROW) {
    spm_addr = spm_write(spm_addr, (uint32_t *)(void *)omrm_spm_row,
                         OMRM_PAYLOAD_WORDS);
  }
}

void omrm_gemm_f16_16_12_16(uint32_t tile, uint32_t x_spm_addr,
                            uint32_t w_spm_addr, uint32_t y_spm_addr)
{
  redmule_gemm_async(tile, x_spm_addr, w_spm_addr, y_spm_addr, 16, 12, 16);
}

void omrm_wait(uint32_t mask)
{
  redmule_wait_all(mask);
}

void omrm_download_f16(uint32_t tile, uint32_t spm_addr, void *destination,
                       uint32_t elements)
{
  omrm_fp16_storage_t *dst = (omrm_fp16_storage_t *)destination;
  uint32_t base;

  omrm_require_complete_rows(elements);
  isolde_set_tile(tile);

  for (base = 0u; base < elements; base += OMRM_FP16_PER_ROW) {
    uint32_t lane;
    spm_addr = spm_read((uint32_t *)(void *)omrm_spm_row, spm_addr,
                        OMRM_PAYLOAD_WORDS);
    for (lane = 0u; lane < OMRM_FP16_PER_ROW; ++lane) {
      dst[base + lane] = omrm_spm_row[lane];
    }
  }
}
