/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * Bare-metal functional test for graph.ll generated from
 * redmule_complex_gemm_12x16x16.onnx.
 */

#include <stdint.h>

#include <bsp/omp_redmule.h>

#include "ai_input.h"
#include "ar_input.h"
#include "bi_input.h"
#include "br_input.h"
#include "ci_golden.h"
#include "cr_golden.h"
#include "tensor_dim.h"

#define GRAPH_OUTPUT_ELEMENTS (M_SIZE * K_SIZE)
#define MAX_ULP_ERROR 2u

typedef uint16_t fp16_storage_t __attribute__((may_alias));

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

static uint16_t load_fp16_bits(const _Float16 *source, uint32_t index)
{
  const fp16_storage_t *bits =
      (const fp16_storage_t *)(const void *)source;
  return bits[index];
}

static uint16_t ordered_fp16_bits(uint16_t bits)
{
  if ((bits & 0x8000u) != 0u)
    return (uint16_t)(~bits);
  return (uint16_t)(bits | 0x8000u);
}

static uint32_t fp16_ulp_distance(uint16_t lhs, uint16_t rhs)
{
  uint16_t ordered_lhs = ordered_fp16_bits(lhs);
  uint16_t ordered_rhs = ordered_fp16_bits(rhs);
  return ordered_lhs >= ordered_rhs
             ? (uint32_t)(ordered_lhs - ordered_rhs)
             : (uint32_t)(ordered_rhs - ordered_lhs);
}

static uint32_t check_component(const fp16_storage_t *actual,
                                const _Float16 *golden,
                                const char *name,
                                uint32_t *worst_ulp)
{
  uint32_t errors = 0u;
  uint32_t index;

  for (index = 0u; index < GRAPH_OUTPUT_ELEMENTS; ++index) {
    uint16_t expected = load_fp16_bits(golden, index);
    uint32_t ulp = fp16_ulp_distance(actual[index], expected);

    if (ulp > *worst_ulp)
      *worst_ulp = ulp;

    if (ulp > MAX_ULP_ERROR) {
      if (errors < 8u) {
        printf("[ONNX-CGEMM] %s[%d][%d] got=0x%04x expected=0x%04x "
               "ulp=%d\n",
               name, (int)(index / K_SIZE), (int)(index % K_SIZE),
               (unsigned)actual[index], (unsigned)expected, (unsigned)ulp);
      }
      ++errors;
    }
  }

  return errors;
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

  errors += check_component(outputs.cr, cr_golden, "Cr", &worst_ulp);
  errors += check_component(outputs.ci, ci_golden, "Ci", &worst_ulp);

  printf("[ONNX-CGEMM] errors=%d worst_ulp=%d allowed_ulp=%d\n",
         (unsigned)errors, (unsigned)worst_ulp, (unsigned)MAX_ULP_ERROR);

  if (errors != 0u) {
    printf("[ONNX-CGEMM] FAILED\n");
    return 1;
  }

  printf("[ONNX-CGEMM] PASSED\n");
  return 0;
}
