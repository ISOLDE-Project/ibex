/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * Host stand-in for the onnx-mlir RedMulE runtime (onnx_redmule_runtime.h),
 * for `make host-test`: runs graph.ll compiled for the host against a model
 * of the tile-private SPMs.  NOT an RTL simulator -- it checks the ABI, the
 * schedule and the data before an RTL run:
 *
 *  - SPM rows of 64 bytes, 16 fp16 payload each (get_addr_start(row) =
 *    row << 6); addresses outside the SPM window abort;
 *  - a GEMM is deferred to the wait that covers it, so a missing wait, or an
 *    operand touched while its launch is in flight, aborts;
 *  - GEMM arithmetic = tformer.py's gemm: FP16 rounding after each of the 16
 *    reduction steps.
 */
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <bsp/onnx_redmule_runtime.h>

enum { TILES = 3, ROWS_PER_TILE = 512, ROW_BYTES = 64, ROW_ELEMS = 16 };

static uint16_t spm[TILES][ROWS_PER_TILE][ROW_ELEMS];
static uint32_t pending, job[TILES][3];
unsigned host_uploads, host_uploaded, host_launches, host_waits, host_downloads;

static uint16_t *element(uint32_t tile, uint32_t addr, uint32_t i)
{
  uint32_t row = addr / ROW_BYTES + i / ROW_ELEMS;
  assert(tile < TILES && addr % ROW_BYTES == 0 && row < ROWS_PER_TILE);
  return &spm[tile][row][i % ROW_ELEMS];
}

static float value(uint16_t bits)
{
  _Float16 h;
  memcpy(&h, &bits, 2);
  return (float)h;
}

static uint16_t bits(float v)
{
  _Float16 h = (_Float16)v;
  uint16_t b;
  memcpy(&b, &h, 2);
  return b;
}

static void idle(uint32_t tile)
{
  assert(tile < TILES && !(pending & (1u << tile)) && "tile busy");
}

uint32_t omrm_addr_start(uint32_t tile, uint32_t bank)
{
  idle(tile);
  return bank * ROW_BYTES;
}

uint32_t omrm_upload_f16(uint32_t tile, uint32_t addr, const void *src,
                         uint32_t elements, uint32_t negate)
{
  idle(tile);
  assert(elements % ROW_ELEMS == 0);
  for (uint32_t i = 0; i < elements; ++i)
    *element(tile, addr, i) =
        (uint16_t)(((const uint16_t *)src)[i] ^ (negate ? 0x8000u : 0u));
  ++host_uploads;
  host_uploaded += elements;
  return addr + elements / ROW_ELEMS * ROW_BYTES;
}

uint32_t omrm_upload_tile_f16(uint32_t tile, uint32_t addr, const void *source,
                              uint32_t src_ld, uint32_t row_offset,
                              uint32_t col_offset, uint32_t rows, uint32_t cols,
                              uint32_t dst_rows, uint32_t dst_cols,
                              uint32_t flags)
{
  const uint16_t *src = (const uint16_t *)source;
  const int transpose = (flags & OMRM_TILE_TRANSPOSE) != 0;
  const uint32_t out_rows = transpose ? cols : rows;
  const uint32_t out_cols = transpose ? rows : cols;
  idle(tile);
  assert(dst_cols == ROW_ELEMS && dst_rows * dst_cols <= OMRM_TILE_MAX_ELEMENTS);
  assert(out_rows <= dst_rows && out_cols <= dst_cols && col_offset + cols <= src_ld);
  for (uint32_t i = 0; i < dst_rows; ++i)
    for (uint32_t j = 0; j < dst_cols; ++j) {
      uint16_t b = 0;
      if (i < out_rows && j < out_cols) {
        uint32_t r = transpose ? j : i, c = transpose ? i : j;
        b = src[(row_offset + r) * src_ld + col_offset + c];
        if ((flags & OMRM_TILE_RELU) && (b & 0x8000u))
          b = 0;
        if (flags & OMRM_TILE_NEGATE)
          b ^= 0x8000u;
      }
      *element(tile, addr, i * ROW_ELEMS + j) = b;
    }
  ++host_uploads;
  host_uploaded += dst_rows * dst_cols;
  return addr + dst_rows * ROW_BYTES;
}

void omrm_zero_f16(uint32_t tile, uint32_t addr, uint32_t elements)
{
  idle(tile);
  assert(elements % ROW_ELEMS == 0);
  for (uint32_t i = 0; i < elements; ++i)
    *element(tile, addr, i) = 0;
}

void omrm_gemm_f16_16_12_16(uint32_t tile, uint32_t x, uint32_t w, uint32_t y)
{
  idle(tile);
  job[tile][0] = x;
  job[tile][1] = w;
  job[tile][2] = y;
  pending |= 1u << tile;
  ++host_launches;
}

void omrm_wait(uint32_t mask)
{
  assert(mask != 0 && (mask & pending) == mask && "wait without launch");
  for (uint32_t tile = 0; tile < TILES; ++tile) {
    if (!(mask & (1u << tile)))
      continue;
    uint16_t y[12][16];
    for (uint32_t m = 0; m < 12; ++m)
      for (uint32_t k = 0; k < 16; ++k) {
        float acc = value(*element(tile, job[tile][2], m * 16 + k));
        for (uint32_t n = 0; n < 16; ++n) {
          float a = value(*element(tile, job[tile][0], m * 16 + n));
          float b = value(*element(tile, job[tile][1], n * 16 + k));
          acc = value(bits(a * b + acc));
        }
        y[m][k] = bits(acc);
      }
    for (uint32_t m = 0; m < 12; ++m)
      for (uint32_t k = 0; k < 16; ++k)
        *element(tile, job[tile][2], m * 16 + k) = y[m][k];
  }
  pending &= ~mask;
  ++host_waits;
}

void omrm_download_f16(uint32_t tile, uint32_t addr, void *dst,
                       uint32_t elements)
{
  idle(tile);
  assert(elements % ROW_ELEMS == 0);
  for (uint32_t i = 0; i < elements; ++i)
    ((uint16_t *)dst)[i] = *element(tile, addr, i);
  ++host_downloads;
}
