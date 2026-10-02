/* SPDX-License-Identifier: Apache-2.0
 *
 * radar_attention with the encoder compiled by onnx-mlir.
 *
 * Same case, same weights, same UART output as isolde/sw/radar_attention
 * (encoder mode), so tformer_uart_viewer.py / tformer_viewer.py and the
 * `make cases` images work unchanged.  The difference: tformer_runtime3()
 * is replaced by graph.ll, onnx-mlir's RedMulE schedule of the ONNX encoder
 * (onnx_radar_model.py -> models/tformer_encoder.onnx): 28 launches, the
 * mean pool and the classifier head included, weights resident in SPM
 * (main_graph_preload, once at boot).
 */
#include <stdint.h>
#include <string.h>
#include <bsp/omp_redmule.h>

#include "tformer_config.h"   /* the export's defines + tf_logits_golden */
#include "tformer_vectors.h"  /* tf_features, tf_class_name, the case id */
#include "graph_info.h"       /* launches / waits / tiles of graph.ll */

#if TF_CHAIN
#error "onnx_radar_attention: chain mode (TF_CHAIN=1) is not supported yet"
#endif

#ifndef TF_DUMP
#define TF_DUMP 1
#endif
/* Same tolerance as radar_attention; onnx-mlir's schedule is bit-exact with
 * the firmware's reference, so worst_ulp should print 0. */
#ifndef MAX_TF_ULP
#define MAX_TF_ULP 4u
#endif

#define TF_WINDOW_ELEMENTS (2u * TF_FRAMES * 16u)

/* The firmware's layout: [2][TF_FRAMES][16], bearing plane then range plane
 * (what [TFWIN] prints).  The ONNX graph takes the row-major [TF_FRAMES][32]
 * matrix x = [bearing | range]. */
static uint16_t window[TF_WINDOW_ELEMENTS] __attribute__((aligned(16)));
static uint16_t graph_x[TF_WINDOW_ELEMENTS] __attribute__((aligned(16)));
static uint16_t logits[TF_CLASSES] __attribute__((aligned(16)));

/* Bare-pointer ABI emitted by the SPADE LLVM lowering. */
extern void main_graph_preload(void);
extern uint16_t *main_graph(const void *x);

/* memref.alloc of the graph result (logits [1][TF_CLASSES]): the only
 * allocation, id 1 (checked by graph_info.py). */
void *_reserveMemory(int32_t id)
{
  if (id == 1)
    return logits;
  printf("[TFORMER] FAILED unexpected graph allocation id=%d\n", (int)id);
  _Exit(0x0bad1000);
  return 0;
}

/* The input case, as in radar_attention: `make cases` writes a replacement
 * for these four objects as one ihex, which OpenOCD's load_image puts in
 * dataram before the core starts.  All four are read through volatile.
 * Not static: clang would merge a static copy with the string literal. */
const volatile char tf_case_id[17] = TF_CASE_ID;
const volatile uint32_t tf_true_class = TF_TRUE_CLASS;
#define TF_CASE_FEATURES ((const volatile uint16_t *)tf_features)
#define TF_CASE_GOLDEN ((const volatile uint16_t *)tf_logits_golden)

static uint32_t ordered(uint16_t bits)
{
  return bits & 0x8000u ? 0x8000u - (bits & 0x7fffu) : 0x8000u + bits;
}

/* radar_attention's tf_argmax: unsigned compare on the monotonic ordering
 * of binary16 bit patterns, no floating point. */
static uint32_t tf_argmax(const uint16_t *values, uint32_t count)
{
  uint32_t i, best = 0, best_key = 0;
  for (i = 0; i < count; ++i) {
    uint32_t key = ordered(values[i]);
    if (i == 0 || key > best_key) {
      best_key = key;
      best = i;
    }
  }
  return best;
}

static uint32_t compare(const uint16_t *actual, const uint16_t *golden,
                        uint32_t count, const char *name, uint32_t *worst)
{
  uint32_t i, errors = 0;
  for (i = 0; i < count; ++i) {
    uint32_t a = ordered(actual[i]), g = ordered(golden[i]);
    uint32_t ulp = a > g ? a - g : g - a;
    if (ulp > *worst) *worst = ulp;
    if (ulp > MAX_TF_ULP) {
      if (errors < 6u)
        printf("[TFORMER] %s[%u] got=%04x expected=%04x ulp=%u\n", name, i,
               (unsigned)actual[i], (unsigned)golden[i], ulp);
      ++errors;
    }
  }
  return errors;
}

/* [2][F][16] tile-major -> [F][32] row-major. */
static void window_to_graph_input(void)
{
  uint32_t plane, frame, j;
  for (plane = 0; plane < 2u; ++plane)
    for (frame = 0; frame < TF_FRAMES; ++frame)
      for (j = 0; j < 16u; ++j)
        graph_x[frame * 32u + plane * 16u + j] =
            window[(plane * TF_FRAMES + frame) * 16u + j];
}

int main(void)
{
  uint32_t errors = 0, worst = 0, predicted, expected, true_class, i;
  uint16_t golden[TF_CLASSES];
  char case_id[sizeof tf_case_id];
  uint16_t *result;

  for (i = 0; i + 1u < sizeof case_id; ++i) case_id[i] = tf_case_id[i];
  case_id[sizeof case_id - 1u] = '\0';
  for (i = 0; i < TF_CLASSES; ++i) golden[i] = TF_CASE_GOLDEN[i];
  expected = tf_argmax(golden, TF_CLASSES);
  true_class = tf_true_class < TF_CLASSES ? tf_true_class : 0u;

  printf("[TFORMER] case=%s weights=%s mode=%s\n", case_id, TF_WEIGHTS_ID,
         "encoder");
  printf("[TFORMER] frames=%u features=%u d_model=%u d_ff=%u layers=%u\n",
         TF_FRAMES, TF_FEATURES, TF_DMODEL, TF_DFF, TF_LAYERS);
  /* The schedule graph.ll actually runs (radar_attention prints its own). */
  printf("[TFORMER] launches=%u barriers=%u\n", (unsigned)GRAPH_LAUNCHES,
         (unsigned)GRAPH_WAITS);

  if (strcmp(TF_CASE_ID, TF_GOLDEN_CASE_ID) != 0) {
    printf("[TFORMER] FAILED vectors case=%s but goldens were exported for "
           "case=%s; re-run make model\n", TF_CASE_ID, TF_GOLDEN_CASE_ID);
    return 1;
  }

  if (isolde_get_tile_cnt() < GRAPH_TILES) {
    printf("[TFORMER] FAILED insufficient RedMulE tiles\n");
    return 1;
  }
  isolde_clear_tile_ip((uint32_t)-1);

  /* Once, at boot: the weights into the tile SPMs (radar_attention uploads
   * them on every inference instead, inside its test-2 cycle count). */
  START_PERFCNT(0x3)
  main_graph_preload();
  STOP_PERFCNT(0x3)
  printPerfCnt();

  START_PERFCNT(0x1)
  for (i = 0; i < TF_WINDOW_ELEMENTS; ++i) window[i] = TF_CASE_FEATURES[i];
  STOP_PERFCNT(0x1)

  START_PERFCNT(0x2)
  window_to_graph_input();
  result = main_graph(graph_x);
  STOP_PERFCNT(0x2)
  printPerfCnt();

  if (result != logits) {
    printf("[TFORMER] FAILED graph result at 0x%x, expected 0x%x\n",
           (unsigned)(uintptr_t)result, (unsigned)(uintptr_t)logits);
    return 1;
  }

  errors += compare(logits, golden, TF_CLASSES, "logit", &worst);
  predicted = tf_argmax(logits, TF_CLASSES);

#if TF_DUMP
  for (i = 0; i < TF_WINDOW_ELEMENTS; ++i)
    printf("[TFWIN] %u %04x\n", i, (unsigned)window[i]);
  for (i = 0; i < TF_CLASSES; ++i)
    printf("[TFLOG] %u %04x\n", i, (unsigned)logits[i]);
#endif

  printf("[TFORMER] class=%s expected=%s true=%s\n",
         tf_class_name[predicted], tf_class_name[expected],
         tf_class_name[true_class]);
  if (predicted != expected) {
    printf("[TFORMER] FAILED class mismatch\n");
    ++errors;
  }
  printf("[TFORMER] errors=%u worst_ulp=%u (tolerance %u)\n", errors, worst,
         MAX_TF_ULP);
  printf("[TFORMER] %s\n", errors ? "FAILED" : "PASSED");
  return errors ? 1 : 0;
}
