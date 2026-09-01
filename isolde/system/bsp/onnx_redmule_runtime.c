/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * Bare-metal RedMulE runtime used by generated ONNX-MLIR objects.
 * FP16 values are always copied as raw storage bits: RV32 performs no scalar
 * half-precision arithmetic in this file.
 */

// #include <stdint.h>

// #include <bsp/omp_redmule.h>
// #include <bsp/onnx_redmule_runtime.h>
// #include <bsp/spm.h>
/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * Bare-metal RedMulE runtime used by generated ONNX-MLIR objects.
 * FP16 values are moved as raw storage bits; RV32 performs no scalar
 * half-precision arithmetic in this file.
 */

#include <stdint.h>

#include <bsp/omp_redmule.h>
#include <bsp/onnx_redmule_runtime.h>
#include <bsp/simple_system_regs.h>
#include <bsp/spm_load.h>

#define OMRM_FP16_PER_ROW    16u
#define OMRM_PAYLOAD_WORDS    8u
#define OMRM_ROW_BYTES       64u
#define OMRM_FP16_SIGN_PAIR  0x80008000u

/* link.ld: loader-visible data RAM. */
extern uint8_t __dmem_start[];
extern uint8_t __dmem_end[];

/* Clang/GCC: permit raw access to the object representation of _Float16. */
typedef uint16_t omrm_fp16_storage_t __attribute__((may_alias));

static void omrm_require_complete_rows(uint32_t elements)
{
  if ((elements % OMRM_FP16_PER_ROW) != 0u) {
    _Exit(0x0bad0010);
  }
}

uint32_t omrm_addr_start(uint32_t tile, uint32_t bank)
{
  if (tile >= isolde_get_tile_cnt()) {
    _Exit(0x0bad0002);
  }

  isolde_set_tile(tile);
  return get_addr_start(bank);
}

uint32_t omrm_upload_f16(uint32_t tile, uint32_t spm_addr,
                         const void *source, uint32_t elements,
                         uint32_t negate)
{
  const omrm_fp16_storage_t *src =
      (const omrm_fp16_storage_t *)source;
  uintptr_t source_addr = (uintptr_t)source;
  const uintptr_t dmem_start = (uintptr_t)__dmem_start;
  const uintptr_t dmem_end = (uintptr_t)__dmem_end;
  const uintptr_t transfer_bytes =
      (uintptr_t)elements * sizeof(omrm_fp16_storage_t);
  uint32_t rows;
  uint32_t row;

  omrm_require_complete_rows(elements);
  if (elements == 0u) {
    return spm_addr;
  }

  if ((source_addr & 1u) != 0u) {
    _Exit(0x0bad0004);
  }

  rows = elements / OMRM_FP16_PER_ROW;
  isolde_set_tile(tile);

  /*
   * Fast path for generated ONNX constants/results in dataram.
   *
   * With the updated isolde_spm_loader RTL the final row's bank 8 is not
   * accessed, so an exact-sized source object is sufficient: no staging row,
   * no guard word, and no CPU tail are required.
   */
  if ((source_addr & 3u) == 0u &&
      transfer_bytes <= dmem_end - dmem_start &&
      source_addr >= dmem_start &&
      source_addr <= dmem_end - transfer_bytes) {
      
      if (negate != 0u) {
        return spm_load_negate_f16(spm_addr, (const uint32_t *)source, elements / 2u);
      }

      return spm_load(spm_addr, (const uint32_t *)source, elements / 2u);
  }

  /*
   * CPU fallback for stack/non-DMEM sources and for negate != 0.
   * Build the narrow 9-bank row layout directly. Bank 8 is populated only
   * when a following row exists, matching the updated loader RTL.
   */
  for (row = 0u; row < rows; ++row) {
    uint32_t word;
    uint32_t fp16_base = row * OMRM_FP16_PER_ROW;
    volatile uint32_t *dst =
        (volatile uint32_t *)(uintptr_t)(SPM_NARROW_ADDR + spm_addr +
                                         row * OMRM_ROW_BYTES);

    for (word = 0u; word < OMRM_PAYLOAD_WORDS; ++word) {
      uint32_t i = fp16_base + 2u * word;
      uint32_t bits = (uint32_t)src[i] | ((uint32_t)src[i + 1u] << 16);
      if (negate != 0u) {
        bits ^= OMRM_FP16_SIGN_PAIR;
      }
      dst[word] = bits;
    }

    if (row + 1u < rows) {
      uint32_t i = fp16_base + OMRM_FP16_PER_ROW;
      uint32_t bits = (uint32_t)src[i] | ((uint32_t)src[i + 1u] << 16);
      if (negate != 0u) {
        bits ^= OMRM_FP16_SIGN_PAIR;
      }
      dst[OMRM_PAYLOAD_WORDS] = bits;
    }
  }

  return spm_addr + rows * OMRM_ROW_BYTES;
}

void omrm_zero_f16(uint32_t tile, uint32_t spm_addr, uint32_t elements)
{
  omrm_require_complete_rows(elements);
  isolde_set_tile(tile);
  (void)spm_fill_zero(spm_addr, elements / 2u);
}

void omrm_gemm_f16_16_12_16(uint32_t tile, uint32_t x_spm_addr,
                            uint32_t w_spm_addr, uint32_t y_spm_addr)
{
  isolde_clear_tile_ip(REDMULE_BIT(tile));
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
  uintptr_t destination_addr = (uintptr_t)destination;
  const uintptr_t dmem_start = (uintptr_t)__dmem_start;
  const uintptr_t dmem_end = (uintptr_t)__dmem_end;
  const uintptr_t transfer_bytes =
      (uintptr_t)elements * sizeof(omrm_fp16_storage_t);
  uint32_t rows;
  uint32_t row;

  omrm_require_complete_rows(elements);
  if (elements == 0u) {
    return;
  }

  if ((destination_addr & 1u) != 0u) {
    _Exit(0x0bad0004);
  }

  rows = elements / OMRM_FP16_PER_ROW;
  isolde_set_tile(tile);

  /* Exact-sized, word-aligned dataram destinations can use the whole loader. */
  if ((destination_addr & 3u) == 0u &&
      transfer_bytes <= dmem_end - dmem_start &&
      destination_addr >= dmem_start &&
      destination_addr <= dmem_end - transfer_bytes) {
    (void)spm_store((uint32_t *)destination, spm_addr, elements / 2u);
    return;
  }

  /* Stack/non-DMEM fallback: copy only the eight payload banks per row. */
  for (row = 0u; row < rows; ++row) {
    uint32_t word;
    uint32_t fp16_base = row * OMRM_FP16_PER_ROW;
    volatile const uint32_t *src =
        (volatile const uint32_t *)(uintptr_t)(SPM_NARROW_ADDR + spm_addr +
                                               row * OMRM_ROW_BYTES);

    for (word = 0u; word < OMRM_PAYLOAD_WORDS; ++word) {
      uint32_t bits = src[word];
      uint32_t i = fp16_base + 2u * word;
      dst[i] = (uint16_t)bits;
      dst[i + 1u] = (uint16_t)(bits >> 16);
    }
  }
}
