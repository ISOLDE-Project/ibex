/*
 * complex_gemm.c
 *
 * Specialized complex FP16 GEMM for:
 *
 *   complex_gemm.py --m 12 --n 16 --k 16 \
 *                   --tile-m 12 --tile-n 16 --tile-k 16 \
 *                   --seed 1 --out-dir ./inc
 *
 * Two RedMulEs:
 *   RM0: Cr = Ar*Br + Ai*(-Bi)
 *   RM1: Ci = Ar*Bi + Ai*Br
 *
 * IMPORTANT FOR RV32IM:
 * CPU-side FP16 data is moved and compared as raw storage bits. There is
 * deliberately no scalar _Float16 arithmetic in this file, so Clang cannot
 * introduce compiler-rt half<->float helpers such as __extendhfsf2 /
 * __truncsfhf2. The sign flip needed for -Bi is a word-wise XOR of bit 15 in
 * both halves, which is an integer operation.
 *
 * TRANSFER STRATEGY
 * -----------------
 * Operands move through isolde_spm_loader (bsp/spm_load.h) rather than the
 * CPU store loop. Three properties of the loader shape the code:
 *
 *   - it moves whole contiguous tensors, so no per-row marshalling buffer is
 *     needed and the bank-8 duplication between consecutive rows comes out
 *     right by construction. Only the FINAL row's guard word is a don't-care;
 *     zeroing the guard on every row, as the previous version did, corrupts
 *     the layout that RedMulE reads.
 *
 *   - it reads one word past the payload to fill that final guard slot. The
 *     generated tensors are exactly M*N elements with no padding, so the last
 *     row is sent through a small scratch instead: bulk via the loader, tail
 *     row via spm_load(). No access ever leaves a generated array.
 *
 *   - sources and destinations must live in data memory. The generated
 *     tensors are .rodata and the buffers here are .bss, both of which
 *     link.ld places in dataram. Stack buffers would NOT work: the stack is
 *     on a separate memory port the loader cannot reach.
 */

#include <stdint.h>

#include <bsp/fp16_utils.h>
#include <bsp/omp_redmule.h>
#include <bsp/spm.h>
#include <bsp/spm_load.h>
#include <bsp/tinyprintf.h>

#include "inc/tensor_dim.h"
#include "inc/ar_input.h"
#include "inc/ai_input.h"
#include "inc/br_input.h"
#include "inc/bi_input.h"
#include "inc/cr_golden.h"
#include "inc/ci_golden.h"

#define RM_REAL 0u
#define RM_IMAG 1u
#define RM_MASK (REDMULE_BIT(RM_REAL) | REDMULE_BIT(RM_IMAG))

#define SPM_PAYLOAD_WORDS 8u  /* NUM_BANKS - 1 */
#define SPM_F16_PER_ROW   16u

#define X_ELEMS (M_SIZE * N_SIZE)
#define W_ELEMS (N_SIZE * K_SIZE)
#define Y_ELEMS (M_SIZE * K_SIZE)

#define X_WORDS (X_ELEMS / 2u)
#define W_WORDS (W_ELEMS / 2u)
#define Y_WORDS (Y_ELEMS / 2u)

#if (M_SIZE != 12) || (N_SIZE != 16) || (K_SIZE != 16)
#error "This program requires --m 12 --n 16 --k 16"
#endif

#if (TILE_M_SIZE != 12) || (TILE_N_SIZE != 16) || (TILE_K_SIZE != 16)
#error "This program requires --tile-m 12 --tile-n 16 --tile-k 16"
#endif

#if (M_TILE_COUNT != 1) || (N_TILE_COUNT != 1) || (K_TILE_COUNT != 1)
#error "This program requires exactly one M/N/K tile"
#endif

#if ((X_ELEMS % SPM_F16_PER_ROW) != 0) || ((W_ELEMS % SPM_F16_PER_ROW) != 0) \
    || ((Y_ELEMS % SPM_F16_PER_ROW) != 0)
#error "Every operand must contain complete 16-FP16 SPM rows"
#endif

/* ------------------------------------------------------------------ */
/* DMEM buffers. All .bss, hence dataram, hence loader-reachable.      */
/* ------------------------------------------------------------------ */

/* Tail row staging: spm_load() reads src[0..8] for one row. */
static uint32_t tail_row[SPM_PAYLOAD_WORDS + 1u];

/* -Bi, produced once per phase by a word-wise sign flip. */
static uint32_t w_negated[W_WORDS];

/* Y starts at zero. .bss is cleared at startup, so this needs no fill loop
 * and no runtime cost beyond the transfer itself. Never written. */
static const uint32_t y_zero[Y_WORDS];

/* Result readback. spm_store() writes dst[0..elems], one word past the
 * payload, so the buffer carries a spare word. */
static uint32_t result[2][Y_WORDS + 1u];

typedef struct {
  uint32_t x;
  uint32_t w;
  uint32_t y;
} spm_layout_t;

static spm_layout_t spm_layout[2];

/* ------------------------------------------------------------------ */
/* Transfer helpers                                                    */
/* ------------------------------------------------------------------ */

/*
 * The loader is a word engine, so every tensor it touches must be
 * word-aligned. The generator emits plain `static const _Float16 x[N]`, whose
 * alignment is not guaranteed to be 4; Ibex traps on a misaligned access
 * rather than fixing it up, so check rather than discover it in a waveform.
 */
static void require_word_aligned(const void *p, const char *what) {
  uintptr_t a = (uintptr_t)p;

  if ((a & 3u) != 0u) {
    printf("[CGEMM] %s is not word aligned (0x%08x)\n", what, (uint32_t)a);
    _Exit(0x0bad0004);
  }
}

/*
 * DMEM -> SPM of the currently selected tile, one contiguous tensor.
 *
 * All rows but the last are one loader descriptor. The last row is copied
 * through tail_row so the guard slot is written as zero instead of reading
 * past the end of `src`. Rows 0..n-2 still receive the following row's first
 * word in bank 8, which is what RedMulE expects.
 */
static uint32_t upload_words(uint32_t addr, const uint32_t *src,
                             uint32_t words) {
  uint32_t bulk = words - SPM_PAYLOAD_WORDS;
  uint32_t i;

  if (bulk != 0u) {
    addr = spm_load(addr, src, bulk);
  }

  for (i = 0u; i < SPM_PAYLOAD_WORDS; ++i) {
    tail_row[i] = src[bulk + i];
  }
  tail_row[SPM_PAYLOAD_WORDS] = 0u;

  return spm_load(addr, tail_row, SPM_PAYLOAD_WORDS);
}

static uint32_t upload_f16(uint32_t addr, const _Float16 *src,
                           uint32_t words, const char *what) {
  require_word_aligned((const void *)src, what);
  return upload_words(addr, (const uint32_t *)(const void *)src, words);
}

/* Flip the FP16 sign bit of both halves of every word. */
static void negate_f16(uint32_t *dst, const _Float16 *src, uint32_t words) {
  const uint32_t *s = (const uint32_t *)(const void *)src;
  uint32_t i;

  require_word_aligned((const void *)src, "negate source");
  for (i = 0u; i < words; ++i) {
    dst[i] = s[i] ^ 0x80008000u;
  }
}

/* ------------------------------------------------------------------ */
/* Operand placement and launch                                        */
/* ------------------------------------------------------------------ */

static void initialize_rm(uint32_t rm, const _Float16 *x, const _Float16 *w,
                          uint32_t negate_w) {
  uint32_t addr;

  isolde_set_tile(rm);
  addr = get_addr_start(0);

  spm_layout[rm].x = addr;
  addr = upload_f16(addr, x, X_WORDS, "X");

  spm_layout[rm].w = addr;
  if (negate_w != 0u) {
    negate_f16(w_negated, w, W_WORDS);
    addr = upload_words(addr, w_negated, W_WORDS);
  } else {
    addr = upload_f16(addr, w, W_WORDS, "W");
  }

  spm_layout[rm].y = addr;
  (void)upload_words(addr, y_zero, Y_WORDS);
}

static void update_xw(uint32_t rm, const _Float16 *x, const _Float16 *w,
                      uint32_t negate_w) {
  isolde_set_tile(rm);

  (void)upload_f16(spm_layout[rm].x, x, X_WORDS, "X");

  if (negate_w != 0u) {
    negate_f16(w_negated, w, W_WORDS);
    (void)upload_words(spm_layout[rm].w, w_negated, W_WORDS);
  } else {
    (void)upload_f16(spm_layout[rm].w, w, W_WORDS, "W");
  }
}

static inline void launch_gemm(uint32_t rm) {
  redmule_gemm_async(rm, spm_layout[rm].x, spm_layout[rm].w, spm_layout[rm].y,
                     TILE_K_SIZE, TILE_M_SIZE, TILE_N_SIZE);
}

static uint32_t check_result(uint32_t rm, const _Float16 *golden,
                             const char *name, uint32_t *worst_ulp) {
  isolde_set_tile(rm);

  /* One transfer, then a plain comparison over a DMEM buffer. */
  (void)spm_store(result[rm], spm_layout[rm].y, Y_WORDS);

  return validate_result((const fp16_storage_t *)(const void *)result[rm],
                         golden, Y_ELEMS, K_SIZE, name, worst_ulp);
}

/* ------------------------------------------------------------------ */

static int run_complex_gemm(uint32_t *errors, uint32_t *worst_ulp) {
  *errors = 0u;
  *worst_ulp = 0u;

  if (isolde_get_tile_cnt() < 2u) {
    printf("[CGEMM] ERROR: at least two RedMulEs are required\n");
    return -1;
  }

  printf("[CGEMM] A=12x16, B=16x16, C=12x16 complex\n");
  printf("[CGEMM] real tile: 12x16 @ 16x16\n");
  printf("[CGEMM] one output tile, one reduction chunk, RM0=Cr RM1=Ci\n");

  /* Phase 1: Cr += Ar*Br, Ci += Ar*Bi, starting from Y=0. */
  initialize_rm(RM_REAL, ar_inp, br_inp, 0u);
  initialize_rm(RM_IMAG, ar_inp, bi_inp, 0u);

  launch_gemm(RM_REAL);
  launch_gemm(RM_IMAG);
  redmule_wait_all(RM_MASK);

  /* Phase 2: Cr += Ai*(-Bi), Ci += Ai*Br. Y is left in place and
   * accumulated into, so only X and W are refreshed. */
  update_xw(RM_REAL, ai_inp, bi_inp, 1u);
  update_xw(RM_IMAG, ai_inp, br_inp, 0u);

  launch_gemm(RM_REAL);
  launch_gemm(RM_IMAG);
  redmule_wait_all(RM_MASK);

  *errors += check_result(RM_REAL, cr_golden, "Cr", worst_ulp);
  *errors += check_result(RM_IMAG, ci_golden, "Ci", worst_ulp);

  return 0;
}

int main(int argc, char **argv) {
  uint32_t errors;
  uint32_t worst_ulp;

  (void)argc;
  (void)argv;

  print_system_info();
  printf("[CGEMM] specialized 12x16x16 complex GEMM (raw FP16 storage)\n");

  isolde_clear_tile_ip((uint32_t)-1);

  START_PERFCNT(0x1)
  if (run_complex_gemm(&errors, &worst_ulp) != 0) {
    return 1;
  }
  STOP_PERFCNT(0x1)
  printPerfCnt();

  printf("[CGEMM] validation: errors=%d worst_ulp=%d allowed_ulp=%d\n", errors,
         worst_ulp, (uint32_t)MAX_ULP_ERROR);

  if (errors != 0u) {
    printf("[CGEMM] FAILED\n");
    return 1;
  }

  printf("[CGEMM] PASSED\n");
  return 0;
}