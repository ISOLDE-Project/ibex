/*
 * complex_gemm.c
 *
 * Software-tiled complex FP16 GEMM on a multi-RedMulE ISOLDE cluster.
 *
 *   C = A * B
 *   A = Ar + jAi
 *   B = Br + jBi
 *
 * Four-real-GEMM mapping:
 *
 *   Cr = Ar*Br + Ai*(-Bi)
 *   Ci = Ar*Bi + Ai*Br
 *
 * RedMulE computes Y <- X*W + Y, so with two RedMulEs one complex output
 * tile maps naturally to two persistent accumulators:
 *
 *   RM(real): Cr
 *   RM(imag): Ci
 *
 * For each reduction tile:
 *   phase 1: Cr += Ar*Br,    Ci += Ar*Bi
 *   phase 2: Cr += Ai*(-Bi), Ci += Ai*Br
 *
 * Cr/Ci remain in their private SPMs across all reduction chunks.
 * The CPU uses one 36-byte SPM-row scratch buffer for all transfers.
 */

#include <stdint.h>

#include <bsp/omp_redmule.h>
#include <bsp/spm.h>
#include <bsp/tinyprintf.h>

#include "inc/tensor_dim.h"
#include "inc/ar_input.h"
#include "inc/ai_input.h"
#include "inc/br_input.h"
#include "inc/bi_input.h"
#include "inc/cr_golden.h"
#include "inc/ci_golden.h"

#ifndef MAX_HW_TILES
#define MAX_HW_TILES 8u
#endif

#ifndef COMPLEX_GEMM_MAX_ULP_ERROR
#define COMPLEX_GEMM_MAX_ULP_ERROR 2u
#endif

#define SPM_PAYLOAD_WORDS  8u
#define SPM_FP16_PER_ROW   16u
#define SPM_GUARD_FP16     2u

#define X_TILE_ELEMS (TILE_M_SIZE * TILE_N_SIZE)
#define W_TILE_ELEMS (TILE_N_SIZE * TILE_K_SIZE)
#define Y_TILE_ELEMS (TILE_M_SIZE * TILE_K_SIZE)

#define X_TILE_WORDS (X_TILE_ELEMS / 2u)
#define W_TILE_WORDS (W_TILE_ELEMS / 2u)
#define Y_TILE_WORDS (Y_TILE_ELEMS / 2u)

#define OUTPUT_TILE_COUNT (M_TILE_COUNT * K_TILE_COUNT)
#define MAX_COMPLEX_WORKERS (MAX_HW_TILES / 2u)

#if (MAX_HW_TILES < 2u)
#error "complex_gemm requires at least two RedMulE tiles"
#endif

#if ((X_TILE_ELEMS % 2u) != 0u) || ((X_TILE_WORDS % SPM_PAYLOAD_WORDS) != 0u)
#error "X tile must contain complete BSP SPM rows"
#endif
#if ((W_TILE_ELEMS % 2u) != 0u) || ((W_TILE_WORDS % SPM_PAYLOAD_WORDS) != 0u)
#error "W tile must contain complete BSP SPM rows"
#endif
#if ((Y_TILE_ELEMS % 2u) != 0u) || ((Y_TILE_WORDS % SPM_PAYLOAD_WORDS) != 0u)
#error "Y tile must contain complete BSP SPM rows"
#endif

static _Float16 spm_row[SPM_FP16_PER_ROW + SPM_GUARD_FP16]
    __attribute__((aligned(4)));

typedef struct {
    uint32_t x[2];
    uint32_t w[2];
    uint32_t y;
} spm_layout_t;

static spm_layout_t spm_layout[MAX_HW_TILES];

static inline uint32_t min_u32(uint32_t a, uint32_t b)
{
    return (a < b) ? a : b;
}

static inline void clear_guard(void)
{
    spm_row[SPM_FP16_PER_ROW + 0u] = (_Float16)0.0f;
    spm_row[SPM_FP16_PER_ROW + 1u] = (_Float16)0.0f;
}

static uint16_t fp16_bits(_Float16 value)
{
    union { _Float16 f; uint16_t u; } cvt;
    cvt.f = value;
    return cvt.u;
}

static _Float16 fp16_from_bits(uint16_t bits)
{
    union { _Float16 f; uint16_t u; } cvt;
    cvt.u = bits;
    return cvt.f;
}

static _Float16 fp16_negate(_Float16 value)
{
    return fp16_from_bits((uint16_t)(fp16_bits(value) ^ 0x8000u));
}

static uint16_t fp16_ordered(uint16_t bits)
{
    if ((bits & 0x8000u) != 0u) {
        return (uint16_t)(~bits);
    }
    return (uint16_t)(bits | 0x8000u);
}

static uint32_t fp16_ulp_distance(_Float16 a, _Float16 b)
{
    const uint16_t oa = fp16_ordered(fp16_bits(a));
    const uint16_t ob = fp16_ordered(fp16_bits(b));
    return (oa >= ob) ? (uint32_t)(oa - ob) : (uint32_t)(ob - oa);
}

typedef enum { A_REAL, A_IMAG } a_component_t;
typedef enum { B_REAL, B_IMAG } b_component_t;

static void fill_a_row(uint32_t m0, uint32_t n0, uint32_t local_offset,
                       a_component_t component)
{
    uint32_t lane;
    for (lane = 0u; lane < SPM_FP16_PER_ROW; ++lane) {
        const uint32_t local = local_offset + lane;
        const uint32_t mi = local / TILE_N_SIZE;
        const uint32_t ni = local % TILE_N_SIZE;
        const uint32_t gm = m0 + mi;
        const uint32_t gn = n0 + ni;

        if ((gm < M_SIZE) && (gn < N_SIZE)) {
            const uint32_t idx = gm * N_SIZE + gn;
            spm_row[lane] = (component == A_REAL) ? ar_inp[idx] : ai_inp[idx];
        } else {
            spm_row[lane] = (_Float16)0.0f;
        }
    }
    clear_guard();
}

static void fill_b_row(uint32_t n0, uint32_t k0, uint32_t local_offset,
                       b_component_t component, uint32_t negate)
{
    uint32_t lane;
    for (lane = 0u; lane < SPM_FP16_PER_ROW; ++lane) {
        const uint32_t local = local_offset + lane;
        const uint32_t ni = local / TILE_K_SIZE;
        const uint32_t ki = local % TILE_K_SIZE;
        const uint32_t gn = n0 + ni;
        const uint32_t gk = k0 + ki;

        if ((gn < N_SIZE) && (gk < K_SIZE)) {
            const uint32_t idx = gn * K_SIZE + gk;
            _Float16 value = (component == B_REAL) ? br_inp[idx] : bi_inp[idx];
            if (negate != 0u) {
                value = fp16_negate(value);
            }
            spm_row[lane] = value;
        } else {
            spm_row[lane] = (_Float16)0.0f;
        }
    }
    clear_guard();
}

static void fill_zero_row(void)
{
    uint32_t lane;
    for (lane = 0u; lane < SPM_FP16_PER_ROW; ++lane) {
        spm_row[lane] = (_Float16)0.0f;
    }
    clear_guard();
}

static uint32_t write_a_tile(uint32_t addr, uint32_t m0, uint32_t n0,
                             a_component_t component)
{
    uint32_t local;
    for (local = 0u; local < X_TILE_ELEMS; local += SPM_FP16_PER_ROW) {
        fill_a_row(m0, n0, local, component);
        addr = spm_write(addr, (uint32_t *)&spm_row[0], SPM_PAYLOAD_WORDS);
    }
    return addr;
}

static uint32_t write_b_tile(uint32_t addr, uint32_t n0, uint32_t k0,
                             b_component_t component, uint32_t negate)
{
    uint32_t local;
    for (local = 0u; local < W_TILE_ELEMS; local += SPM_FP16_PER_ROW) {
        fill_b_row(n0, k0, local, component, negate);
        addr = spm_write(addr, (uint32_t *)&spm_row[0], SPM_PAYLOAD_WORDS);
    }
    return addr;
}

static uint32_t write_zero_tile(uint32_t addr, uint32_t elems)
{
    uint32_t local;

    fill_zero_row();

    for (local = 0u; local < elems; local += SPM_FP16_PER_ROW) {
        addr = spm_write(addr, (uint32_t *)&spm_row[0], SPM_PAYLOAD_WORDS);
    }

    return addr;
}

static uint32_t write_zero_y_tile(uint32_t addr)
{
    return write_zero_tile(addr, Y_TILE_ELEMS);
}

/*
 * Allocate two independent X/W address sets:
 *
 *   slot 0: X0, W0
 *   slot 1: X1, W1
 *   Y:      persistent accumulator
 *
 * With the default 12x16x16 tile this is:
 *
 *   X0 : rows  0..11
 *   W0 : rows 12..27
 *   X1 : rows 28..39
 *   W1 : rows 40..55
 *   Y  : rows 56..67
 *
 * Only X/W addresses ping-pong. Y intentionally remains fixed because
 * RedMulE implements Y <- X*W + Y and must preserve the partial sum.
 */
static void initialize_spm(uint32_t hw_tile,
                           uint32_t m0, uint32_t n0, uint32_t k0,
                           a_component_t acomp, b_component_t bcomp,
                           uint32_t negate_b)
{
    uint32_t addr;

    isolde_set_tile(hw_tile);
    addr = get_addr_start(0);

    /* Slot 0 contains the operands for the first launch. */
    spm_layout[hw_tile].x[0] = addr;
    addr = write_a_tile(addr, m0, n0, acomp);

    spm_layout[hw_tile].w[0] = addr;
    addr = write_b_tile(addr, n0, k0, bcomp, negate_b);

    /*
     * Reserve slot 1 with real SPM writes. Phase 2 overwrites these rows
     * before launching, so no operand contents are reused from slot 0.
     */
    spm_layout[hw_tile].x[1] = addr;
    addr = write_zero_tile(addr, X_TILE_ELEMS);

    spm_layout[hw_tile].w[1] = addr;
    addr = write_zero_tile(addr, W_TILE_ELEMS);

    /* Y is the only intentionally persistent/reused buffer. */
    spm_layout[hw_tile].y = addr;
    (void)write_zero_y_tile(addr);

    printf(
        "[CGEMM] RM%d pingpong "
        "X0=0x%08x W0=0x%08x X1=0x%08x W1=0x%08x Y=0x%08x\n",
        hw_tile,
        spm_layout[hw_tile].x[0],
        spm_layout[hw_tile].w[0],
        spm_layout[hw_tile].x[1],
        spm_layout[hw_tile].w[1],
        spm_layout[hw_tile].y);
}

static void update_xw_slot(uint32_t hw_tile,
                           uint32_t slot,
                           uint32_t m0, uint32_t n0, uint32_t k0,
                           a_component_t acomp, b_component_t bcomp,
                           uint32_t negate_b)
{
    isolde_set_tile(hw_tile);

    (void)write_a_tile(
        spm_layout[hw_tile].x[slot],
        m0, n0, acomp);

    (void)write_b_tile(
        spm_layout[hw_tile].w[slot],
        n0, k0, bcomp, negate_b);
}

static inline void launch_real_gemm(uint32_t hw_tile, uint32_t slot)
{
    redmule_gemm_async(
        hw_tile,
        spm_layout[hw_tile].x[slot],
        spm_layout[hw_tile].w[slot],
        spm_layout[hw_tile].y,
        TILE_K_SIZE,
        TILE_M_SIZE,
        TILE_N_SIZE);
}

static uint32_t check_component_tile(uint32_t hw_tile,
                                     uint32_t m0, uint32_t k0,
                                     const _Float16 *golden,
                                     const char *name,
                                     uint32_t *worst_ulp)
{
    uint32_t addr;
    uint32_t local;
    uint32_t errors = 0u;

    isolde_set_tile(hw_tile);
    addr = spm_layout[hw_tile].y;

    for (local = 0u; local < Y_TILE_ELEMS; local += SPM_FP16_PER_ROW) {
        uint32_t lane;
        addr = spm_read((uint32_t *)&spm_row[0], addr, SPM_PAYLOAD_WORDS);

        for (lane = 0u; lane < SPM_FP16_PER_ROW; ++lane) {
            const uint32_t elem = local + lane;
            const uint32_t mi = elem / TILE_K_SIZE;
            const uint32_t ki = elem % TILE_K_SIZE;
            const uint32_t gm = m0 + mi;
            const uint32_t gk = k0 + ki;

            if ((gm < M_SIZE) && (gk < K_SIZE)) {
                const uint32_t idx = gm * K_SIZE + gk;
                const uint32_t ulp = fp16_ulp_distance(spm_row[lane], golden[idx]);

                if (ulp > *worst_ulp) {
                    *worst_ulp = ulp;
                }
                if (ulp > COMPLEX_GEMM_MAX_ULP_ERROR) {
                    if (errors < 8u) {
                        printf("[CGEMM] %s[%d][%d] got=0x%04x golden=0x%04x ulp=%d\n",
                               name, gm, gk,
                               (uint32_t)fp16_bits(spm_row[lane]),
                               (uint32_t)fp16_bits(golden[idx]), ulp);
                    }
                    ++errors;
                }
            }
        }
    }
    return errors;
}


#ifndef COMPLEX_GEMM_WAIT_SPINS
#define COMPLEX_GEMM_WAIT_SPINS 4096u
#endif

/*
 * Wait for exactly one RedMulE completion using the sticky IP bit.
 * No WFI is used, so this diagnostic cannot lose a wakeup.
 */
static int wait_one_redmule(uint32_t hw_tile, const char *tag)
{
    const uint32_t bit = REDMULE_BIT(hw_tile);
    uint32_t spin;

    for (spin = 0u; spin < COMPLEX_GEMM_WAIT_SPINS; ++spin) {
        const uint32_t pending = isolde_get_tile_ip() & bit;

        if (pending != 0u) {
            isolde_clear_tile_ip(pending);
            printf("[CGEMM] %s RM%d done spin=%d status=0x%08x\n",
                   tag, hw_tile, spin, isolde_get_tile_status());
            return 0;
        }
    }

    printf("[CGEMM] TIMEOUT %s RM%d status=0x%08x ip=0x%08x\n",
           tag,
           hw_tile,
           isolde_get_tile_status(),
           isolde_get_tile_ip());

    return -1;
}

static int run_complex_gemm(uint32_t *errors, uint32_t *worst_ulp)
{
    uint32_t hw_tiles = isolde_get_tile_cnt();
    uint32_t worker_pairs;
    uint32_t batch;

    *errors = 0u;
    *worst_ulp = 0u;

    hw_tiles = min_u32(hw_tiles, MAX_HW_TILES);
    hw_tiles = min_u32(hw_tiles, 32u);

    if (hw_tiles < 2u) {
        printf("[CGEMM] ERROR: at least two RedMulEs are required\n");
        return -1;
    }

    worker_pairs = min_u32(hw_tiles / 2u, MAX_COMPLEX_WORKERS);

    printf("[CGEMM] A=%dx%d, B=%dx%d, C=%dx%d complex\n",
           M_SIZE, N_SIZE, N_SIZE, K_SIZE, M_SIZE, K_SIZE);
    printf("[CGEMM] real tile: %dx%d @ %dx%d\n",
           TILE_M_SIZE, TILE_N_SIZE, TILE_N_SIZE, TILE_K_SIZE);
    printf("[CGEMM] output tiles=%d reduction chunks=%d RedMulEs=%d pairs=%d\n",
           OUTPUT_TILE_COUNT, N_TILE_COUNT, hw_tiles, worker_pairs);

    for (batch = 0u; batch < OUTPUT_TILE_COUNT; batch += worker_pairs) {
        const uint32_t active = min_u32(worker_pairs, OUTPUT_TILE_COUNT - batch);
        uint32_t m0[MAX_COMPLEX_WORKERS];
        uint32_t k0[MAX_COMPLEX_WORKERS];
        uint32_t worker;
        uint32_t n_tile;

        for (worker = 0u; worker < active; ++worker) {
            const uint32_t output_id = batch + worker;
            const uint32_t mt = output_id / K_TILE_COUNT;
            const uint32_t kt = output_id % K_TILE_COUNT;
            m0[worker] = mt * TILE_M_SIZE;
            k0[worker] = kt * TILE_K_SIZE;
        }

        for (n_tile = 0u; n_tile < N_TILE_COUNT; ++n_tile) {
            const uint32_t n0 = n_tile * TILE_N_SIZE;
            uint32_t mask = 0u;

            /* Phase 1: Cr += Ar*Br, Ci += Ar*Bi. */
            for (worker = 0u; worker < active; ++worker) {
                const uint32_t rm_real = 2u * worker;
                const uint32_t rm_imag = rm_real + 1u;

                if (n_tile == 0u) {
                    initialize_spm(rm_real, m0[worker], n0, k0[worker],
                                   A_REAL, B_REAL, 0u);
                    initialize_spm(rm_imag, m0[worker], n0, k0[worker],
                                   A_REAL, B_IMAG, 0u);
                } else {
                    update_xw_slot(rm_real, 0u, m0[worker], n0, k0[worker],
                                   A_REAL, B_REAL, 0u);
                    update_xw_slot(rm_imag, 0u, m0[worker], n0, k0[worker],
                                   A_REAL, B_IMAG, 0u);
                }

                /*
                 * SERIALIZED diagnostic:
                 * do not overlap the two RedMulEs.
                 */
                printf("[CGEMM] phase1 launch RM%d slot0\n", rm_real);
                launch_real_gemm(rm_real, 0u);
                if (wait_one_redmule(rm_real, "phase1") != 0) {
                    return -1;
                }

                printf("[CGEMM] phase1 launch RM%d slot0\n", rm_imag);
                launch_real_gemm(rm_imag, 0u);
                if (wait_one_redmule(rm_imag, "phase1") != 0) {
                    return -1;
                }

                mask |= REDMULE_BIT(rm_real) | REDMULE_BIT(rm_imag);
            }

            /* Phase 2: Cr += Ai*(-Bi), Ci += Ai*Br. */
            mask = 0u;
            for (worker = 0u; worker < active; ++worker) {
                const uint32_t rm_real = 2u * worker;
                const uint32_t rm_imag = rm_real + 1u;

                update_xw_slot(rm_real, 1u, m0[worker], n0, k0[worker],
                               A_IMAG, B_IMAG, 1u);
                update_xw_slot(rm_imag, 1u, m0[worker], n0, k0[worker],
                               A_IMAG, B_REAL, 0u);

                printf("[CGEMM] phase2 launch RM%d slot1\n", rm_real);
                launch_real_gemm(rm_real, 1u);
                if (wait_one_redmule(rm_real, "phase2") != 0) {
                    return -1;
                }

                printf("[CGEMM] phase2 launch RM%d slot1\n", rm_imag);
                launch_real_gemm(rm_imag, 1u);
                if (wait_one_redmule(rm_imag, "phase2") != 0) {
                    return -1;
                }

                mask |= REDMULE_BIT(rm_real) | REDMULE_BIT(rm_imag);
            }
        }

        for (worker = 0u; worker < active; ++worker) {
            const uint32_t rm_real = 2u * worker;
            const uint32_t rm_imag = rm_real + 1u;

            *errors += check_component_tile(rm_real, m0[worker], k0[worker],
                                            cr_golden, "Cr", worst_ulp);
            *errors += check_component_tile(rm_imag, m0[worker], k0[worker],
                                            ci_golden, "Ci", worst_ulp);
        }
    }

    return 0;
}

int main(int argc, char **argv)
{
    uint32_t errors;
    uint32_t worst_ulp;

    (void)argc;
    (void)argv;

    print_system_info();
    printf("[CGEMM] software-tiled complex GEMM\n");
    printf("[CGEMM] TEST MODE: X/W address ping-pong, Y persistent\n");
    printf("[CGEMM] TEST MODE: SERIAL RedMulEs + sticky-IP polling\n");

    isolde_clear_tile_ip((uint32_t)-1);

    if (run_complex_gemm(&errors, &worst_ulp) != 0) {
        return 1;
    }

    printf("[CGEMM] validation: errors=%d worst_ulp=%d allowed_ulp=%d\n",
           errors, worst_ulp, (uint32_t)COMPLEX_GEMM_MAX_ULP_ERROR);

    if (errors != 0u) {
        printf("[CGEMM] FAILED\n");
        return 1;
    }

    printf("[CGEMM] PASSED\n");
    return 0;
}