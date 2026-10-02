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

/* Staging for omrm_upload_tile_f16: word-aligned and in dataram, so the
 * final omrm_upload_f16 takes the loader fast path. */
static omrm_fp16_storage_t omrm_tile_stage[OMRM_TILE_MAX_ELEMENTS]
    __attribute__((aligned(16)));

uint32_t omrm_upload_tile_f16(uint32_t tile, uint32_t spm_addr,
                              const void *source, uint32_t src_ld,
                              uint32_t row_offset, uint32_t col_offset,
                              uint32_t rows, uint32_t cols,
                              uint32_t dst_rows, uint32_t dst_cols,
                              uint32_t flags)
{
  const omrm_fp16_storage_t *src = (const omrm_fp16_storage_t *)source;
  const uint32_t transpose = flags & OMRM_TILE_TRANSPOSE;
  const uint32_t out_rows = transpose ? cols : rows;
  const uint32_t out_cols = transpose ? rows : cols;
  uint32_t i;
  uint32_t j;

  if (dst_cols != OMRM_FP16_PER_ROW ||
      dst_rows * dst_cols > OMRM_TILE_MAX_ELEMENTS ||
      out_rows > dst_rows || out_cols > dst_cols ||
      col_offset + cols > src_ld) {
    _Exit(0x0bad0011);
  }

  /* Plain whole-matrix copy: no staging needed. */
  if (flags == 0u && row_offset == 0u && col_offset == 0u &&
      src_ld == OMRM_FP16_PER_ROW && cols == OMRM_FP16_PER_ROW &&
      rows == dst_rows) {
    return omrm_upload_f16(tile, spm_addr, source, rows * dst_cols, 0u);
  }

  for (i = 0u; i < dst_rows; ++i) {
    for (j = 0u; j < dst_cols; ++j) {
      uint16_t bits = 0u;
      if (i < out_rows && j < out_cols) {
        const uint32_t r = transpose ? j : i;
        const uint32_t c = transpose ? i : j;
        bits = src[(row_offset + r) * src_ld + col_offset + c];
        if ((flags & OMRM_TILE_RELU) != 0u && (bits & 0x8000u) != 0u) {
          bits = 0u;
        }
        if ((flags & OMRM_TILE_NEGATE) != 0u) {
          bits ^= 0x8000u;
        }
      }
      omrm_tile_stage[i * dst_cols + j] = bits;
    }
  }
  return omrm_upload_f16(tile, spm_addr, omrm_tile_stage,
                         dst_rows * dst_cols, 0u);
}

void omrm_zero_f16(uint32_t tile, uint32_t spm_addr, uint32_t elements)
{
  omrm_require_complete_rows(elements);
  isolde_set_tile(tile);
  (void)spm_fill_zero(spm_addr, elements / 2u);
}

#ifndef OMRM_SPM_VIA_DMEM

/* One SPM row in the narrow window: 8 payload words, then bank 8. */
static inline volatile uint32_t *omrm_spm_row(uint32_t spm_addr, uint32_t row)
{
  return (volatile uint32_t *)(uintptr_t)(SPM_NARROW_ADDR + spm_addr +
                                          row * OMRM_ROW_BYTES);
}

/* Write one row's payload and, for every row but the first, refresh bank 8
 * of the previous row with this row's first word. */
static void omrm_spm_put_row(uint32_t spm_addr, uint32_t row,
                             const uint32_t words[OMRM_PAYLOAD_WORDS])
{
  volatile uint32_t *dst = omrm_spm_row(spm_addr, row);
  uint32_t w;
  for (w = 0u; w < OMRM_PAYLOAD_WORDS; ++w) {
    dst[w] = words[w];
  }
  if (row > 0u) {
    omrm_spm_row(spm_addr, row - 1u)[OMRM_PAYLOAD_WORDS] = words[0];
  }
}

static inline uint32_t omrm_relu_pair(uint32_t bits)
{
  if ((bits & 0x00008000u) != 0u) {
    bits &= 0xffff0000u;
  }
  if ((bits & 0x80000000u) != 0u) {
    bits &= 0x0000ffffu;
  }
  return bits;
}

void omrm_spm_relu_f16(uint32_t tile, uint32_t spm_addr, uint32_t rows)
{
  uint32_t row;
  uint32_t w;
  uint32_t words[OMRM_PAYLOAD_WORDS];

  isolde_set_tile(tile);
  for (row = 0u; row < rows; ++row) {
    volatile uint32_t *src = omrm_spm_row(spm_addr, row);
    for (w = 0u; w < OMRM_PAYLOAD_WORDS; ++w) {
      words[w] = omrm_relu_pair(src[w]);
    }
    omrm_spm_put_row(spm_addr, row, words);
  }
}

void omrm_spm_transpose_f16(uint32_t tile, uint32_t src_addr,
                            uint32_t dst_addr, uint32_t rows,
                            uint32_t dst_rows)
{
  omrm_fp16_storage_t m[OMRM_FP16_PER_ROW * OMRM_FP16_PER_ROW];
  uint32_t words[OMRM_PAYLOAD_WORDS];
  uint32_t i;
  uint32_t j;

  if (rows > OMRM_FP16_PER_ROW || dst_rows > OMRM_FP16_PER_ROW) {
    _Exit(0x0bad0012);
  }
  isolde_set_tile(tile);
  for (i = 0u; i < rows; ++i) {
    volatile uint32_t *src = omrm_spm_row(src_addr, i);
    for (j = 0u; j < OMRM_PAYLOAD_WORDS; ++j) {
      uint32_t bits = src[j];
      m[i * OMRM_FP16_PER_ROW + 2u * j] = (omrm_fp16_storage_t)bits;
      m[i * OMRM_FP16_PER_ROW + 2u * j + 1u] =
          (omrm_fp16_storage_t)(bits >> 16);
    }
  }
  for (i = 0u; i < dst_rows; ++i) {
    for (j = 0u; j < OMRM_PAYLOAD_WORDS; ++j) {
      const uint32_t c0 = 2u * j;
      const uint32_t c1 = c0 + 1u;
      const uint32_t lo = c0 < rows ? m[c0 * OMRM_FP16_PER_ROW + i] : 0u;
      const uint32_t hi = c1 < rows ? m[c1 * OMRM_FP16_PER_ROW + i] : 0u;
      words[j] = lo | (hi << 16);
    }
    omrm_spm_put_row(dst_addr, i, words);
  }
}

void omrm_spm_copy_f16(uint32_t tile, uint32_t src_addr, uint32_t dst_addr,
                       uint32_t rows)
{
  uint32_t words[OMRM_PAYLOAD_WORDS];
  uint32_t row;
  uint32_t w;

  isolde_set_tile(tile);
  for (row = 0u; row < rows; ++row) {
    volatile uint32_t *src = omrm_spm_row(src_addr, row);
    for (w = 0u; w < OMRM_PAYLOAD_WORDS; ++w) {
      words[w] = src[w];
    }
    omrm_spm_put_row(dst_addr, row, words);
  }
}

#else /* OMRM_SPM_VIA_DMEM */

/*
 * The same three transforms through data memory, built only from the
 * loader paths that onnx_tiling_gemm / onnx_complex_gemm validated on RTL:
 * omrm_download_f16 into a staging buffer, then omrm_upload_tile_f16 (ReLU
 * and transpose are upload flags) or omrm_upload_f16.  Slower; meant to
 * tell a problem of the narrow-window code above from one elsewhere.
 * Build with TEST_CPPFLAGS=-DOMRM_SPM_VIA_DMEM.
 */
static omrm_fp16_storage_t omrm_xform_stage[OMRM_TILE_MAX_ELEMENTS]
    __attribute__((aligned(16)));

static void omrm_xform_download(uint32_t tile, uint32_t spm_addr,
                                uint32_t rows)
{
  if (rows == 0u || rows * OMRM_FP16_PER_ROW > OMRM_TILE_MAX_ELEMENTS) {
    _Exit(0x0bad0015);
  }
  omrm_download_f16(tile, spm_addr, omrm_xform_stage,
                    rows * OMRM_FP16_PER_ROW);
}

void omrm_spm_relu_f16(uint32_t tile, uint32_t spm_addr, uint32_t rows)
{
  omrm_xform_download(tile, spm_addr, rows);
  (void)omrm_upload_tile_f16(tile, spm_addr, omrm_xform_stage,
                             OMRM_FP16_PER_ROW, 0u, 0u, rows,
                             OMRM_FP16_PER_ROW, rows, OMRM_FP16_PER_ROW,
                             OMRM_TILE_RELU);
}

void omrm_spm_transpose_f16(uint32_t tile, uint32_t src_addr,
                            uint32_t dst_addr, uint32_t rows,
                            uint32_t dst_rows)
{
  if (dst_rows > OMRM_FP16_PER_ROW) {
    _Exit(0x0bad0012);
  }
  omrm_xform_download(tile, src_addr, rows);
  /* The rows x dst_rows window, transposed: dst_rows x rows, zero padded. */
  (void)omrm_upload_tile_f16(tile, dst_addr, omrm_xform_stage,
                             OMRM_FP16_PER_ROW, 0u, 0u, rows, dst_rows,
                             dst_rows, OMRM_FP16_PER_ROW,
                             OMRM_TILE_TRANSPOSE);
}

void omrm_spm_copy_f16(uint32_t tile, uint32_t src_addr, uint32_t dst_addr,
                       uint32_t rows)
{
  omrm_xform_download(tile, src_addr, rows);
  (void)omrm_upload_f16(tile, dst_addr, omrm_xform_stage,
                        rows * OMRM_FP16_PER_ROW, 0u);
}

#endif /* OMRM_SPM_VIA_DMEM */

/* Staging for omrm_spm_move_f16: separate from omrm_tile_stage, which
 * omrm_upload_tile_f16 fills from it. */
static omrm_fp16_storage_t omrm_move_stage[OMRM_TILE_MAX_ELEMENTS]
    __attribute__((aligned(16)));

void omrm_spm_move_f16(uint32_t src_tile, uint32_t src_addr,
                       uint32_t dst_tile, uint32_t dst_addr, uint32_t rows,
                       uint32_t dst_rows, uint32_t flags)
{
  if (rows * OMRM_FP16_PER_ROW > OMRM_TILE_MAX_ELEMENTS) {
    _Exit(0x0bad0013);
  }
  omrm_download_f16(src_tile, src_addr, omrm_move_stage,
                    rows * OMRM_FP16_PER_ROW);
  (void)omrm_upload_tile_f16(dst_tile, dst_addr, omrm_move_stage,
                             OMRM_FP16_PER_ROW, 0u, 0u, rows,
                             OMRM_FP16_PER_ROW, dst_rows, OMRM_FP16_PER_ROW,
                             flags);
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

/* Staging for omrm_download_tile_f16: whole SPM rows land here (loader fast
 * path), then the requested corner is copied out with the caller's stride. */
static omrm_fp16_storage_t omrm_download_stage[OMRM_TILE_MAX_ELEMENTS]
    __attribute__((aligned(16)));

void omrm_download_tile_f16(uint32_t tile, uint32_t spm_addr,
                            void *destination, uint32_t dst_ld,
                            uint32_t rows, uint32_t cols)
{
  omrm_fp16_storage_t *dst = (omrm_fp16_storage_t *)destination;
  uint32_t r;
  uint32_t c;

  if (rows == 0u || cols == 0u) {
    return;
  }
  if (cols > OMRM_FP16_PER_ROW ||
      rows * OMRM_FP16_PER_ROW > OMRM_TILE_MAX_ELEMENTS ||
      (rows > 1u && dst_ld < cols) ||
      (((uintptr_t)destination) & 1u) != 0u) {
    _Exit(0x0bad0014);
  }

  omrm_download_f16(tile, spm_addr, omrm_download_stage,
                    rows * OMRM_FP16_PER_ROW);
  for (r = 0u; r < rows; ++r) {
    for (c = 0u; c < cols; ++c) {
      dst[r * dst_ld + c] = omrm_download_stage[r * OMRM_FP16_PER_ROW + c];
    }
  }
}
