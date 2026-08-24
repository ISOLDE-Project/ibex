/*
 * complex_gemm_12x16x16_rawbits.c
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
 * CPU-side FP16 data is moved and compared as raw uint16_t storage bits.
 * There is deliberately no scalar _Float16 arithmetic in this file, so
 * Clang cannot introduce compiler-rt half<->float helpers such as
 * __extendhfsf2 / __truncsfhf2.
 */

#include <stdint.h>
#include <bsp/spm.h>
#include <bsp/tinyprintf.h>
#include <bsp/omp_redmule.h>

#include "inc/tensor_dim.h"
#include "inc/ar_input.h"
#include "inc/ai_input.h"
#include "inc/br_input.h"
#include "inc/bi_input.h"
#include "inc/cr_golden.h"
#include "inc/ci_golden.h"

#ifndef COMPLEX_GEMM_MAX_ULP_ERROR
#define COMPLEX_GEMM_MAX_ULP_ERROR 2u
#endif

#define RM_REAL 0u
#define RM_IMAG 1u
#define RM_MASK (REDMULE_BIT(RM_REAL) | REDMULE_BIT(RM_IMAG))

#define SPM_PAYLOAD_WORDS 8u
#define SPM_FP16_PER_ROW  16u
#define SPM_GUARD_FP16    2u

#define X_ELEMS (M_SIZE * N_SIZE)
#define W_ELEMS (N_SIZE * K_SIZE)
#define Y_ELEMS (M_SIZE * K_SIZE)

#if (M_SIZE != 12) || (N_SIZE != 16) || (K_SIZE != 16)
#error "This program requires --m 12 --n 16 --k 16"
#endif

#if (TILE_M_SIZE != 12) || (TILE_N_SIZE != 16) || (TILE_K_SIZE != 16)
#error "This program requires --tile-m 12 --tile-n 16 --tile-k 16"
#endif

#if (M_TILE_COUNT != 1) || (N_TILE_COUNT != 1) || (K_TILE_COUNT != 1)
#error "This program requires exactly one M/N/K tile"
#endif

#if ((X_ELEMS % SPM_FP16_PER_ROW) != 0)
#error "X must contain complete 16-FP16 SPM rows"
#endif

#if ((W_ELEMS % SPM_FP16_PER_ROW) != 0)
#error "W must contain complete 16-FP16 SPM rows"
#endif

#if ((Y_ELEMS % SPM_FP16_PER_ROW) != 0)
#error "Y must contain complete 16-FP16 SPM rows"
#endif

/*
 * may_alias lets us access the storage representation of the generated
 * _Float16 arrays as uint16_t without asking Clang to perform a FP conversion.
 */
typedef uint16_t fp16_storage_t __attribute__((may_alias));

/* 16 FP16 payload entries + two BSP guard entries = 36 bytes. */
static fp16_storage_t spm_row[SPM_FP16_PER_ROW + SPM_GUARD_FP16]
    __attribute__((aligned(4)));

typedef struct {
    uint32_t x;
    uint32_t w;
    uint32_t y;
} spm_layout_t;

static spm_layout_t spm_layout[2];

static inline uint16_t load_fp16_bits(const _Float16 *src, uint32_t index)
{
    const fp16_storage_t *bits =
        (const fp16_storage_t *)(const void *)src;
    return bits[index];
}

static inline uint16_t fp16_negate_bits(uint16_t bits)
{
    return (uint16_t)(bits ^ 0x8000u);
}

static inline uint16_t fp16_ordered_bits(uint16_t bits)
{
    if ((bits & 0x8000u) != 0u) {
        return (uint16_t)(~bits);
    }
    return (uint16_t)(bits | 0x8000u);
}

static inline uint32_t fp16_ulp_distance_bits(uint16_t a, uint16_t b)
{
    const uint16_t oa = fp16_ordered_bits(a);
    const uint16_t ob = fp16_ordered_bits(b);

    return (oa >= ob)
        ? (uint32_t)(oa - ob)
        : (uint32_t)(ob - oa);
}

static inline void clear_guard(void)
{
    spm_row[SPM_FP16_PER_ROW + 0u] = 0u;
    spm_row[SPM_FP16_PER_ROW + 1u] = 0u;
}

static uint32_t write_fp16_matrix_bits(uint32_t addr,
                                       const _Float16 *src,
                                       uint32_t elems,
                                       uint32_t negate)
{
    uint32_t base;

    for (base = 0u; base < elems; base += SPM_FP16_PER_ROW) {
        uint32_t lane;

        for (lane = 0u; lane < SPM_FP16_PER_ROW; ++lane) {
            uint16_t bits = load_fp16_bits(src, base + lane);

            if (negate != 0u) {
                bits = fp16_negate_bits(bits);
            }

            spm_row[lane] = bits;
        }

        clear_guard();
        addr = spm_write(addr, (uint32_t *)(void *)&spm_row[0],
                         SPM_PAYLOAD_WORDS);
    }

    return addr;
}

static uint32_t write_zero_matrix_bits(uint32_t addr, uint32_t elems)
{
    uint32_t base;
    uint32_t lane;

    for (lane = 0u; lane < SPM_FP16_PER_ROW; ++lane) {
        spm_row[lane] = 0u;
    }
    clear_guard();

    for (base = 0u; base < elems; base += SPM_FP16_PER_ROW) {
        addr = spm_write(addr, (uint32_t *)(void *)&spm_row[0],
                         SPM_PAYLOAD_WORDS);
    }

    return addr;
}

static void initialize_rm(uint32_t rm,
                          const _Float16 *x,
                          const _Float16 *w,
                          uint32_t negate_w)
{
    uint32_t addr;

    isolde_set_tile(rm);
    addr = get_addr_start(0);

    spm_layout[rm].x = addr;
    addr = write_fp16_matrix_bits(addr, x, X_ELEMS, 0u);

    spm_layout[rm].w = addr;
    addr = write_fp16_matrix_bits(addr, w, W_ELEMS, negate_w);

    spm_layout[rm].y = addr;
    (void)write_zero_matrix_bits(addr, Y_ELEMS);
}

static void update_xw(uint32_t rm,
                      const _Float16 *x,
                      const _Float16 *w,
                      uint32_t negate_w)
{
    isolde_set_tile(rm);

    (void)write_fp16_matrix_bits(spm_layout[rm].x, x, X_ELEMS, 0u);
    (void)write_fp16_matrix_bits(spm_layout[rm].w, w, W_ELEMS, negate_w);
}

static inline void launch_gemm(uint32_t rm)
{
    redmule_gemm_async(
        rm,
        spm_layout[rm].x,
        spm_layout[rm].w,
        spm_layout[rm].y,
        TILE_K_SIZE,
        TILE_M_SIZE,
        TILE_N_SIZE);
}

static uint32_t check_result(uint32_t rm,
                             const _Float16 *golden,
                             const char *name,
                             uint32_t *worst_ulp)
{
    uint32_t addr;
    uint32_t base;
    uint32_t errors = 0u;

    isolde_set_tile(rm);
    addr = spm_layout[rm].y;

    for (base = 0u; base < Y_ELEMS; base += SPM_FP16_PER_ROW) {
        uint32_t lane;

        addr = spm_read((uint32_t *)(void *)&spm_row[0], addr,
                        SPM_PAYLOAD_WORDS);

        for (lane = 0u; lane < SPM_FP16_PER_ROW; ++lane) {
            const uint32_t idx = base + lane;
            const uint32_t row = idx / K_SIZE;
            const uint32_t col = idx % K_SIZE;
            const uint16_t got_bits = spm_row[lane];
            const uint16_t golden_bits = load_fp16_bits(golden, idx);
            const uint32_t ulp =
                fp16_ulp_distance_bits(got_bits, golden_bits);

            if (ulp > *worst_ulp) {
                *worst_ulp = ulp;
            }

            if (ulp > COMPLEX_GEMM_MAX_ULP_ERROR) {
                if (errors < 8u) {
                    printf("[CGEMM] %s[%d][%d] got=0x%04x golden=0x%04x ulp=%d\n",
                           name,
                           row,
                           col,
                           (uint32_t)got_bits,
                           (uint32_t)golden_bits,
                           ulp);
                }
                ++errors;
            }
        }
    }

    return errors;
}

static int run_complex_gemm(uint32_t *errors, uint32_t *worst_ulp)
{
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

    /* Phase 2: Cr += Ai*(-Bi), Ci += Ai*Br. */
    update_xw(RM_REAL, ai_inp, bi_inp, 1u);
    update_xw(RM_IMAG, ai_inp, br_inp, 0u);

    launch_gemm(RM_REAL);
    launch_gemm(RM_IMAG);
    redmule_wait_all(RM_MASK);

    *errors += check_result(RM_REAL, cr_golden, "Cr", worst_ulp);
    *errors += check_result(RM_IMAG, ci_golden, "Ci", worst_ulp);

    return 0;
}

int main(int argc, char **argv)
{
    uint32_t errors;
    uint32_t worst_ulp;

    (void)argc;
    (void)argv;

    print_system_info();
    printf("[CGEMM] specialized 12x16x16 complex GEMM (raw FP16 storage)\n");

    isolde_clear_tile_ip((uint32_t)-1);

    if (run_complex_gemm(&errors, &worst_ulp) != 0) {
        return 1;
    }

    printf("[CGEMM] validation: errors=%d worst_ulp=%d allowed_ulp=%d\n",
           errors,
           worst_ulp,
           (uint32_t)COMPLEX_GEMM_MAX_ULP_ERROR);

    if (errors != 0u) {
        printf("[CGEMM] FAILED\n");
        return 1;
    }

    printf("[CGEMM] PASSED\n");
    return 0;
}