/* SPDX-License-Identifier: Apache-2.0 */
#include <stdint.h>
#include <bsp/omp_redmule.h>
#include "beamform_runtime.h"
#include "radar_vectors.h"

#ifndef BF_USE_ONNX
#define BF_USE_ONNX 0
#endif
#ifndef BF_DUMP
#define BF_DUMP 1
#endif

static uint16_t result_r[BF_M * BF_K] __attribute__((aligned(16)));
static uint16_t result_i[BF_M * BF_K] __attribute__((aligned(16)));

#if BF_USE_ONNX
typedef struct { uint16_t *cr, *ci; } graph_outputs_t;
extern graph_outputs_t main_graph(const void *, const void *, const void *, const void *);
static uint16_t graph_r[BF_BLOCK_M * BF_K] __attribute__((aligned(16)));
static uint16_t graph_i[BF_BLOCK_M * BF_K] __attribute__((aligned(16)));

/* Same allocation contract as the existing onnx_complex_gemm application.
 * Inspect generated graph.ll after compiler updates: unexpected IDs fail.
 */
void *_reserveMemory(int32_t id)
{
  if (id == 1) return graph_r;
  if (id == 2) return graph_i;
  printf("[RADAR] FAILED unexpected allocation id=%d\n", (int)id);
  _Exit(1);
}

static void beamform_onnx(void)
{
  uint32_t block, j;
  for (block = 0; block < BF_M / BF_BLOCK_M; ++block) {
    uint32_t offset = block * BF_BLOCK_M * BF_N;
    graph_outputs_t out = main_graph(bf_ar + offset, bf_ai + offset, bf_br, bf_bi);
    if (!out.cr || !out.ci) {
      printf("[RADAR] FAILED null graph output\n");
      _Exit(1);
    }
    for (j = 0; j < BF_BLOCK_M * BF_K; ++j) {
      result_r[block * BF_BLOCK_M * BF_K + j] = out.cr[j];
      result_i[block * BF_BLOCK_M * BF_K + j] = out.ci[j];
    }
  }
}
#endif

static uint32_t ordered(uint16_t bits)
{
  return bits & 0x8000u ? 0x8000u - (bits & 0x7fffu) : 0x8000u + bits;
}

/* Exact signed Q24 conversion for binary16 magnitudes below 64.
 * This demo's outputs are below 2. No floating point library is needed.
 */
static int32_t q24(uint16_t bits)
{
  uint32_t exponent = (bits >> 10) & 31u;
  uint32_t fraction = bits & 1023u;
  int32_t value = (int32_t)(exponent ? (1024u + fraction) << (exponent - 1u)
                                   : fraction);
  return bits & 0x8000u ? -value : value;
}

static uint32_t validate(const uint16_t *actual, const uint16_t *golden,
                         const char *component, uint32_t *worst_ulp)
{
  uint32_t i, errors = 0;
  for (i = 0; i < BF_M * BF_K; ++i) {
    uint32_t a = ordered(actual[i]), g = ordered(golden[i]);
    uint32_t ulp = a > g ? a - g : g - a;
    uint32_t bad;
    if (ulp > *worst_ulp) *worst_ulp = ulp;
    /* Reject NaN, infinity and implausible outputs before bounded Q24 math. */
    if ((actual[i] & 0x7c00u) >= 0x5400u ||
        (golden[i] & 0x7c00u) >= 0x5400u) {
      bad = 1;
    } else {
      int32_t diff = q24(actual[i]) - q24(golden[i]);
      uint32_t delta = (uint32_t)(diff < 0 ? -diff : diff);
      /* <= 4 ULP OR <= 2^-12 absolute amplitude; needed near cancellation. */
      bad = ulp > 4u && delta > 4096u;
    }
    if (bad) {
      if (errors < 6u)
        printf("[RADAR] %s[%u] got=%04x expected=%04x ulp=%u\n",
               component, i, (unsigned)actual[i], (unsigned)golden[i], ulp);
      ++errors;
    }
  }
  return errors;
}

int main(void)
{
  uint32_t errors, worst_ulp = 0;
  printf("[RADAR] case=%s mode=%s rows=%u cols=%u\n", BF_CASE_ID,
         BF_USE_ONNX ? "onnx2" : "runtime3", BF_M, BF_K);
  if (isolde_get_tile_cnt() < (BF_USE_ONNX ? 2u : 3u)) {
    printf("[RADAR] FAILED insufficient RedMulE tiles\n");
    return 1;
  }
  isolde_clear_tile_ip(BF_USE_ONNX ? 0x3u : 0x7u);
  START_PERFCNT(0x1)
#if BF_USE_ONNX
  beamform_onnx();
#else
  beamform_runtime3(bf_ar, bf_ai, bf_br, bf_bi, result_r, result_i);
#endif
  STOP_PERFCNT(0x1)
  printPerfCnt();
  errors = validate(result_r, bf_cr_golden, "Cr", &worst_ulp);
  errors += validate(result_i, bf_ci_golden, "Ci", &worst_ulp);
  printf("[RADAR] errors=%u worst_ulp=%u (4 ULP OR abs<=2^-12)\n", errors, worst_ulp);
#if BF_DUMP
  for (uint32_t i = 0; i < BF_M * BF_K; ++i)
    printf("[BF16] %u %04x %04x\n", i, (unsigned)result_r[i], (unsigned)result_i[i]);
#endif
  printf("[RADAR] %s\n", errors ? "FAILED" : "PASSED");
  return errors ? 1 : 0;
}
