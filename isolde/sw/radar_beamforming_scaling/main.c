/* SPDX-License-Identifier: Apache-2.0 */
#include <stdint.h>
/* The production BSP supplies tinyprintf and declares putchar(char).
 * Do not include libc stdio.h here: its putchar(int) declaration conflicts.
 * The host-only omp_redmule shim supplies host stdio for unit tests.
 */
#include <bsp/omp_redmule.h>
#include "bench_config.h"
#include "bench_cycles.h"
#include "beamform_scaling.h"
#include "inc/radar_vectors.h"

_Static_assert(BF_M == 36 && BF_N == 16 && BF_K == 16 && BF_BLOCK_M == 12,
               "The BSP supports fixed 12x16x16 blocks in a 36-beam scan");
static uint16_t result_r[BF_M * BF_K] __attribute__((aligned(16)));
static uint16_t result_i[BF_M * BF_K] __attribute__((aligned(16)));

/* Same finite/range/ULP/absolute-error checks as the original application. */
static uint32_t ordered(uint16_t bits)
{
  return bits & 0x8000u ? 0x8000u - (bits & 0x7fffu) : 0x8000u + bits;
}
static int32_t q24(uint16_t bits)
{
  uint32_t exponent = (bits >> 10) & 31u, fraction = bits & 1023u;
  int32_t value = (int32_t)(exponent ? (1024u + fraction) << (exponent - 1u)
                                   : fraction);
  return bits & 0x8000u ? -value : value;
}
static unsigned validate(const uint16_t *actual, const uint16_t *golden,
                         unsigned *worst_ulp)
{
  unsigned errors = 0;
  for (unsigned i = 0; i < BF_M * BF_K; ++i) {
    uint32_t a = ordered(actual[i]), g = ordered(golden[i]);
    unsigned ulp = a > g ? a - g : g - a;
    if (ulp > *worst_ulp) *worst_ulp = ulp;
    if ((actual[i] & 0x7c00u) >= 0x5400u || (golden[i] & 0x7c00u) >= 0x5400u) {
      ++errors;
    } else {
      int32_t diff = q24(actual[i]) - q24(golden[i]);
      uint32_t delta = (uint32_t)(diff < 0 ? -diff : diff);
      errors += ulp > 4u && delta > 4096u;
    }
  }
  return errors;
}

static unsigned run_scan(unsigned instances, int measured, uint32_t *cycles,
                         unsigned *worst_ulp)
{
  /* Poison outputs before the timed region so a missing download cannot
   * accidentally validate against the preceding configuration's results.
   */
  for (unsigned i = 0; i < BF_M * BF_K; ++i)
    result_r[i] = result_i[i] = 0x7e00u;
  isolde_clear_tile_ip((1u << instances) - 1u);
  if (measured) {
    bf_bench_start();
    beamform_scaling(instances, bf_ar, bf_ai, bf_br, bf_bi, result_r, result_i);
    *cycles = bf_bench_stop();
  } else {
    beamform_scaling(instances, bf_ar, bf_ai, bf_br, bf_bi, result_r, result_i);
  }
  unsigned errors = validate(result_r, bf_cr_golden, worst_ulp);
  return errors + validate(result_i, bf_ci_golden, worst_ulp);
}

int main(void)
{
  unsigned tiles = isolde_get_tile_cnt(), samples = 0;
  printf("[BF_BENCH] BEGIN version=2 case=%s rows=36 inner=16 cols=16 block_rows=12 "
         "repeats=%u warmups=%u tiles=%u counter=aida_perfcnt counter_bits=32 "
         "scope=end_to_end source=%s\n",
         BF_CASE_ID, (unsigned)BF_BENCH_REPEATS, (unsigned)BF_BENCH_WARMUPS,
         tiles, BF_BENCH_SOURCE);
  if (tiles < 3u) {
    printf("[BF_BENCH] FAIL reason=insufficient_tiles required=3 available=%u\n", tiles);
    printf("[BF_BENCH] END status=FAIL samples=0\n");
    return 1;
  }
  for (unsigned instances = 1; instances <= 3; ++instances) {
    for (unsigned warmup = 0; warmup != (unsigned)BF_BENCH_WARMUPS; ++warmup) {
      uint32_t ignored = 0;
      unsigned worst = 0, errors = run_scan(instances, 0, &ignored, &worst);
      if (errors) {
        printf("[BF_BENCH] FAIL reason=warmup_validation instances=%u errors=%u\n",
               instances, errors);
        printf("[BF_BENCH] END status=FAIL samples=0\n");
        return 1;
      }
    }
  }
  /* Rotate 1/2/3, 2/3/1, 3/1/2 to reduce fixed-order effects. */
  for (unsigned repeat = 0; repeat < (unsigned)BF_BENCH_REPEATS; ++repeat) {
    for (unsigned slot = 0; slot < 3; ++slot) {
      unsigned instances = (repeat + slot) % 3u + 1u, worst = 0;
      uint32_t cycles = 0;
      unsigned errors = run_scan(instances, 1, &cycles, &worst);
      ++samples;
      printf("[BF_BENCH] SAMPLE instances=%u repeat=%u cycles_hi=%u cycles_lo=%u "
             "errors=%u worst_ulp=%u status=%s\n", instances, repeat,
             0u, (unsigned)cycles, errors, worst,
             errors || !cycles ? "FAIL" : "PASS");
      if (errors || !cycles) {
        printf("[BF_BENCH] END status=FAIL samples=%u\n", samples);
        return 1;
      }
    }
  }
  printf("[BF_BENCH] END status=PASS samples=%u\n", samples);
  return 0;
}
