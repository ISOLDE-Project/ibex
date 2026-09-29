/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * Bare-metal RTL test of onnx-mlir's RedMulE Gemm tiling, on the
 * radar_attention projection:
 *
 *   h[12,16] = window[12,32] . tf_proj[32,16] + tf_pos[12,16]
 *
 * graph.ll is `onnx-mlir --EmitSPADELLVM` of models/proj.onnx (proj_onnx.py,
 * MatMul + Add).  onnx-mlir fuses them into one Gemm and aisle-tile splits it
 * into two K-tile launches: Y = pos, Y += X0 . W0, Y += X1 . W1 -- the
 * firmware's launch_bias + launch_accumulate.  tf_proj is split at compile
 * time into two 16x16 tiles that stay resident in SPM (main_graph_preload).
 *
 * The result must be bit-exact with inc/proj_golden.h, written by the same
 * proj_onnx.py run (RedMulE FP16 arithmetic of radar_attention/tformer.py).
 * main_graph runs twice: the second run checks that the resident weights
 * survived the first.
 */

#include <stddef.h>
#include <bsp/omp_redmule.h>
#include <bsp/fp16_utils.h>

#include "proj_golden.h"
#include "proj_window.h"
#include "tensor_dim.h"

#define H_ELEMENTS (FRAMES * D_MODEL)
#define RUNS 2

/* Exact match expected; set -DPROJ_ALLOWED_ULP=n to accept n FP16 ULP. */
#ifndef PROJ_ALLOWED_ULP
#define PROJ_ALLOWED_ULP 0u
#endif

/* Bare-pointer ABI emitted by the SPADE LLVM lowering. */
extern void main_graph_preload(void);
extern fp16_storage_t *main_graph(const void *window);

static fp16_storage_t graph_h[H_ELEMENTS] __attribute__((aligned(16)));

/* memref.alloc of the result: the graph's only allocation, id 1. */
void *_reserveMemory(int32_t id)
{
  if (id == 1)
    return graph_h;
  printf("[ONNX-TGEMM] unexpected allocation id=%d\n", (int)id);
  _Exit(0x0bad1000);
  return NULL;
}

int main(int argc, char **argv)
{
  uint32_t errors = 0u;
  uint32_t worst_ulp = 0u;
  unsigned run;
  unsigned i;

  (void)argc;
  (void)argv;

  printf("[ONNX-TGEMM] graph.ll bare-metal test\n");
  printf("[ONNX-TGEMM] h[%d,%d] = window[%d,%d] . W[%d,%d] + pos, FP16\n",
         FRAMES, D_MODEL, FRAMES, FEATURES, FEATURES, D_MODEL);

  if (isolde_get_tile_cnt() < 1u) {
    printf("[ONNX-TGEMM] ERROR: no RedMulE tile\n");
    return 1;
  }
  isolde_clear_tile_ip((uint32_t)-1);

  /* Once, at boot: resident weights into the SPM of tile 0. */
  START_PERFCNT(0x1)
  main_graph_preload();
  STOP_PERFCNT(0x1)
  printf("[ONNX-TGEMM] preload:\n");
  printPerfCnt();

  for (run = 0; run < RUNS; ++run) {
    fp16_storage_t *h;
    uint32_t run_worst = 0u;

    /* A result that is never written must not look right. */
    for (i = 0; i < H_ELEMENTS; ++i)
      graph_h[i] = 0x7e00u; /* NaN */

    START_PERFCNT(0x2)
    h = main_graph((const void *)window_inp);
    STOP_PERFCNT(0x2)
    printf("[ONNX-TGEMM] inference %d:\n", (int)run);
    printPerfCnt();

    if (h != graph_h) {
      printf("[ONNX-TGEMM] ERROR: result at 0x%x, expected 0x%x\n",
             (unsigned)(uintptr_t)h, (unsigned)(uintptr_t)graph_h);
      return 1;
    }
    /* validate_result reports (and counts) values beyond MAX_ULP_ERROR;
     * the exact-match requirement is checked on worst_ulp below. */
    errors += validate_result(h, (const _Float16 *)(const void *)h_golden,
                              H_ELEMENTS, D_MODEL, "h", &run_worst);
    printf("[ONNX-TGEMM] run %d worst_ulp=%d\n", (int)run, (unsigned)run_worst);
    if (run_worst > worst_ulp)
      worst_ulp = run_worst;
  }

  printf("[ONNX-TGEMM] errors=%d worst_ulp=%d allowed_ulp=%d\n",
         (unsigned)errors, (unsigned)worst_ulp, (unsigned)PROJ_ALLOWED_ULP);
  if (errors != 0u || worst_ulp > PROJ_ALLOWED_ULP) {
    printf("[ONNX-TGEMM] FAILED\n");
    return 1;
  }
  printf("[ONNX-TGEMM] PASSED\n");
  return 0;
}
