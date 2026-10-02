/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * Bare-metal RTL test of onnx-mlir's RedMulE schedule for the ISOLDE
 * transformer blocks (onnx-mlir test-isolde/transformer), by default one
 * encoder layer of the radar_attention model:
 *
 *   y[12,16] = h1 + FFN(h1),  h1 = h + MultiHeadAttention(h, h)
 *
 * graph.ll is `onnx-mlir --EmitSPADELLVM` of models/transformer_<BLOCK>.onnx
 * (transformer_app.py).  Every product is a native RedMulE launch
 * Y[12x16] (+)= X[12x16] . W[16x16]; intermediates stay in the tile-private
 * SPMs (ReLU and K^T are done in SPM, or on the way between tiles), constant
 * weights are resident (main_graph_preload), and with onnx-mlir 0008+ Q, K
 * and V run on RedMulE tiles 0, 1 and 2 in parallel.
 *
 * The result must be bit-exact with inc/tf_golden.h, written by the same
 * transformer_app.py run (RedMulE FP16 arithmetic of radar_attention's
 * tformer.py; with SOURCE=firmware it is also the firmware's own stage
 * golden).  main_graph runs twice: the second run checks that the resident
 * weights survived the first.
 */

#include <stddef.h>
#include <bsp/omp_redmule.h>
#include <bsp/fp16_utils.h>

#include "graph_info.h"
#include "tensor_dim.h"
#include "tf_golden.h"
#include "tf_input.h"

#define Y_ELEMENTS (FRAMES * D_MODEL)
#define RUNS 2

/* Exact match expected; set -DTF_ALLOWED_ULP=n to accept n FP16 ULP. */
#ifndef TF_ALLOWED_ULP
#define TF_ALLOWED_ULP 1u
#endif

/* Bare-pointer ABI emitted by the SPADE LLVM lowering. */
extern void main_graph_preload(void);
extern fp16_storage_t *main_graph(const void *h);

static fp16_storage_t graph_y[Y_ELEMENTS] __attribute__((aligned(16)));

/* memref.alloc of the result: the graph's only allocation, id 1 (checked by
 * graph_info.py).  Cross-tile moves stage through the runtime's own buffer. */
void *_reserveMemory(int32_t id)
{
  if (id == 1)
    return graph_y;
  printf("[ONNX-TFMR] unexpected allocation id=%d\n", (int)id);
  _Exit(0x0bad1000);
  return NULL;
}

int main(int argc, char **argv)
{
  uint32_t errors = 0u;
  uint32_t worst_ulp = 0u;
  unsigned tiles;
  unsigned run;
  unsigned i;

  (void)argc;
  (void)argv;

  printf("[ONNX-TFMR] graph.ll bare-metal test, block %s\n", BLOCK_NAME);
  printf("[ONNX-TFMR] in[%d,%d] -> y[%d,%d], d_ff=%d, FP16\n", FRAMES,
         IN_COLS, FRAMES, D_MODEL, D_FF);
  printf("[ONNX-TFMR] schedule: %d launches, %d waits, %d tile(s)\n",
         (unsigned)GRAPH_LAUNCHES, (unsigned)GRAPH_WAITS,
         (unsigned)GRAPH_TILES);

  tiles = isolde_get_tile_cnt();
  printf("[ONNX-TFMR] platform: %d RedMulE tile(s)\n", tiles);
  if (tiles < GRAPH_TILES) {
    printf("[ONNX-TFMR] ERROR: graph.ll needs %d tiles\n",
           (unsigned)GRAPH_TILES);
    return 1;
  }
  isolde_clear_tile_ip((uint32_t)-1);

  /* Once, at boot: resident weights into the tile SPMs. */
  START_PERFCNT(0x1)
  main_graph_preload();
  STOP_PERFCNT(0x1)
  printf("[ONNX-TFMR] preload:\n");
  printPerfCnt();

  for (run = 0; run < RUNS; ++run) {
    fp16_storage_t *y;
    uint32_t run_worst = 0u;

    /* A result that is never written must not look right. */
    for (i = 0; i < Y_ELEMENTS; ++i)
      graph_y[i] = 0x7e00u; /* NaN */

    START_PERFCNT(0x2)
    y = main_graph((const void *)tf_input);
    STOP_PERFCNT(0x2)
    printf("[ONNX-TFMR] inference %d:\n", (int)run);
    printPerfCnt();

    if (y != graph_y) {
      printf("[ONNX-TFMR] ERROR: result at 0x%x, expected 0x%x\n",
             (unsigned)(uintptr_t)y, (unsigned)(uintptr_t)graph_y);
      return 1;
    }
    /* validate_result reports (and counts) values beyond MAX_ULP_ERROR;
     * the exact-match requirement is checked on worst_ulp below. */
    errors += validate_result(y, (const _Float16 *)(const void *)tf_golden,
                              Y_ELEMENTS, D_MODEL, "y", &run_worst);
    printf("[ONNX-TFMR] run %d worst_ulp=%d\n", (int)run, (unsigned)run_worst);
    if (run_worst > worst_ulp)
      worst_ulp = run_worst;
  }

  printf("[ONNX-TFMR] errors=%d worst_ulp=%d allowed_ulp=%d\n",
         (unsigned)errors, (unsigned)worst_ulp, (unsigned)TF_ALLOWED_ULP);
  if (errors != 0u || worst_ulp > TF_ALLOWED_ULP) {
    printf("[ONNX-TFMR] FAILED\n");
    return 1;
  }
  printf("[ONNX-TFMR] PASSED\n");
  return 0;
}
