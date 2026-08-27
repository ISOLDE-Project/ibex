/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * Bare-metal functional test for graph.ll 
 */



#include <bsp/omp_redmule.h>
#include <bsp/fp16_utils.h>

#include "ai_input.h"
#include "ar_input.h"
#include "bi_input.h"
#include "br_input.h"
#include "ci_golden.h"
#include "cr_golden.h"
#include "tensor_dim.h"

#define GRAPH_OUTPUT_ELEMENTS (M_SIZE * K_SIZE)




typedef struct {
  fp16_storage_t *cr;
  fp16_storage_t *ci;
} graph_outputs_t;

/* Bare-pointer ABI emitted by the current SPADE LLVM lowering. */
extern graph_outputs_t main_graph(const void *ar, const void *ai,
                                  const void *br, const void *bi);

static fp16_storage_t graph_cr[GRAPH_OUTPUT_ELEMENTS]
    __attribute__((aligned(16)));
static fp16_storage_t graph_ci[GRAPH_OUTPUT_ELEMENTS]
    __attribute__((aligned(16)));

/* memref.alloc lowering assigns the two current output allocations IDs 1/2. */
void *_reserveMemory(int32_t id)
{
  if (id == 1)
    return graph_cr;
  if (id == 2)
    return graph_ci;

  printf("[ONNX-CGEMM] unexpected allocation id=%d\n", (int)id);
  _Exit(0x0bad1000);
}




int main(int argc, char **argv)
{
  graph_outputs_t outputs;
  uint32_t errors = 0u;
  uint32_t worst_ulp = 0u;

  (void)argc;
  (void)argv;

  printf("[ONNX-CGEMM] graph.ll bare-metal test\n");
  printf("[ONNX-CGEMM] A=12x16, B=16x16, C=12x16 split-complex FP16\n");

  if (isolde_get_tile_cnt() < 2u) {
    printf("[ONNX-CGEMM] ERROR: at least two RedMulE tiles are required\n");
    return 1;
  }

  isolde_clear_tile_ip((uint32_t)-1);
  outputs = main_graph((const void *)ar_inp, (const void *)ai_inp,
                       (const void *)br_inp, (const void *)bi_inp);

  if (outputs.cr == 0 || outputs.ci == 0) {
    printf("[ONNX-CGEMM] ERROR: graph returned a null output\n");
    return 1;
  }

  errors += validate_result(outputs.cr, cr_golden, GRAPH_OUTPUT_ELEMENTS, K_SIZE,"Cr", &worst_ulp);
  errors += validate_result(outputs.ci, ci_golden, GRAPH_OUTPUT_ELEMENTS, K_SIZE, "Ci", &worst_ulp);

  printf("[ONNX-CGEMM] errors=%d worst_ulp=%d allowed_ulp=%d\n",
         (unsigned)errors, (unsigned)worst_ulp, (unsigned)MAX_ULP_ERROR);

  if (errors != 0u) {
    printf("[ONNX-CGEMM] FAILED\n");
    return 1;
  }

  printf("[ONNX-CGEMM] PASSED\n");
  return 0;
}
