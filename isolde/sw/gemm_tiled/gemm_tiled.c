/*
 * gemm_tiled.c
 *
 * Low-RAM software-tiled FP16 GEMM for the ISOLDE RedMulE cluster.
 *
 * RedMulE notation:
 *
 *   Z[M x K] = Y[M x K] + X[M x N] * W[N x K]
 *
 * Full tensors can be larger than one RedMulE operation. Software partitions
 * them into fixed-size accelerator tiles:
 *
 *   X_tile : TILE_M_SIZE x TILE_N_SIZE
 *   W_tile : TILE_N_SIZE x TILE_K_SIZE
 *   Y_tile : TILE_M_SIZE x TILE_K_SIZE
 *
 * The SPM loader RTL used with this program does not access bank 8 of the
 * final transferred row. Therefore an exact 8-word/16-FP16 row is sufficient:
 * no source or destination guard word is required.
 *
 * A single 32-byte row workspace is retained because software must gather
 * strided/padded pieces of the full X/W/Y tensors into the packed RedMulE tile
 * layout. The workspace is static (.bss), so it is visible to the SPM loader.
 */

#include <stdint.h>
#include <bsp/spm_load.h>
#include <bsp/tinyprintf.h>
#include <bsp/omp_redmule.h>

#include "inc/tensor_dim.h"
#include "inc/x_input.h"
#include "inc/w_input.h"
#include "inc/y_input.h"
#include "inc/golden.h"

/* -------------------------------------------------------------------------- */
/* Configuration                                                              */
/* -------------------------------------------------------------------------- */

#ifndef MAX_HW_TILES
#define MAX_HW_TILES 8u
#endif

#ifndef GEMM_MAX_ULP_ERROR
#define GEMM_MAX_ULP_ERROR 2u
#endif

/*
 * SPM geometry:
 *
 *   physical banks   = 9
 *   payload per row  = 8 uint32_t words
 *   FP16 per row     = 16
 *
 * Bank 8 duplicates bank 0 of the following row for all non-final rows.
 * With the revised loader, the final row stops at bank 7.
 */
#define SPM_PAYLOAD_WORDS  8u
#define SPM_FP16_PER_ROW  (2u * SPM_PAYLOAD_WORDS)

#define X_TILE_ELEMS (TILE_M_SIZE * TILE_N_SIZE)
#define W_TILE_ELEMS (TILE_N_SIZE * TILE_K_SIZE)
#define Y_TILE_ELEMS (TILE_M_SIZE * TILE_K_SIZE)

#define X_TILE_WORDS (X_TILE_ELEMS / 2u)
#define W_TILE_WORDS (W_TILE_ELEMS / 2u)
#define Y_TILE_WORDS (Y_TILE_ELEMS / 2u)

#define OUTPUT_TILE_COUNT (M_TILE_COUNT * K_TILE_COUNT)

/* -------------------------------------------------------------------------- */
/* Compile-time checks                                                        */
/* -------------------------------------------------------------------------- */

#if ((X_TILE_ELEMS % 2u) != 0u)
#error "X tile must contain an even number of FP16 elements"
#endif

#if ((W_TILE_ELEMS % 2u) != 0u)
#error "W tile must contain an even number of FP16 elements"
#endif

#if ((Y_TILE_ELEMS % 2u) != 0u)
#error "Y tile must contain an even number of FP16 elements"
#endif

#if ((X_TILE_WORDS % SPM_PAYLOAD_WORDS) != 0u)
#error "X tile must occupy complete BSP SPM payload rows"
#endif

#if ((W_TILE_WORDS % SPM_PAYLOAD_WORDS) != 0u)
#error "W tile must occupy complete BSP SPM payload rows"
#endif

#if ((Y_TILE_WORDS % SPM_PAYLOAD_WORDS) != 0u)
#error "Y tile must occupy complete BSP SPM payload rows"
#endif

/* -------------------------------------------------------------------------- */
/* Tiny CPU-side working set                                                  */
/* -------------------------------------------------------------------------- */

/*
 * Exactly one SPM payload row.
 *
 * No guard word is needed with the revised isolde_spm_loader RTL.
 * Keep this in static storage because the loader can access dataram/.bss but
 * cannot access the separate stack memory.
 *
 * may_alias is useful with Clang because the loader API exposes the same
 * storage as uint32_t words while the CPU fills/checks it as FP16.
 */
typedef _Float16 spm_fp16_t __attribute__((may_alias));

static spm_fp16_t spm_row[SPM_FP16_PER_ROW]
    __attribute__((aligned(32)));

typedef struct {
    uint32_t x;
    uint32_t w;
    uint32_t y;
} tile_spm_layout_t;

static tile_spm_layout_t spm_layout[MAX_HW_TILES];

/* -------------------------------------------------------------------------- */
/* Generic helpers                                                            */
/* -------------------------------------------------------------------------- */

static inline uint32_t min_u32(uint32_t a, uint32_t b)
{
    return (a < b) ? a : b;
}

/* -------------------------------------------------------------------------- */
/* FP16 validation helpers                                                    */
/* -------------------------------------------------------------------------- */

static uint16_t fp16_bits(_Float16 value)
{
    union {
        _Float16 f;
        uint16_t u;
    } conv;

    conv.f = value;
    return conv.u;
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

    return (oa >= ob)
        ? (uint32_t)(oa - ob)
        : (uint32_t)(ob - oa);
}

/* -------------------------------------------------------------------------- */
/* Fill one SPM payload row from X                                            */
/* -------------------------------------------------------------------------- */

static void fill_x_row(
    uint32_t m0,
    uint32_t n0,
    uint32_t local_offset)
{
    uint32_t lane;

    for (lane = 0u; lane < SPM_FP16_PER_ROW; ++lane) {
        const uint32_t local = local_offset + lane;
        const uint32_t mi = local / TILE_N_SIZE;
        const uint32_t ni = local % TILE_N_SIZE;

        const uint32_t gm = m0 + mi;
        const uint32_t gn = n0 + ni;

        if ((gm < M_SIZE) && (gn < N_SIZE)) {
            spm_row[lane] = x_inp[gm * N_SIZE + gn];
        } else {
            spm_row[lane] = (_Float16)0.0f;
        }
    }
}

/* -------------------------------------------------------------------------- */
/* Fill one SPM payload row from W                                            */
/* -------------------------------------------------------------------------- */

static void fill_w_row(
    uint32_t n0,
    uint32_t k0,
    uint32_t local_offset)
{
    uint32_t lane;

    for (lane = 0u; lane < SPM_FP16_PER_ROW; ++lane) {
        const uint32_t local = local_offset + lane;
        const uint32_t ni = local / TILE_K_SIZE;
        const uint32_t ki = local % TILE_K_SIZE;

        const uint32_t gn = n0 + ni;
        const uint32_t gk = k0 + ki;

        if ((gn < N_SIZE) && (gk < K_SIZE)) {
            spm_row[lane] = w_inp[gn * K_SIZE + gk];
        } else {
            spm_row[lane] = (_Float16)0.0f;
        }
    }
}

/* -------------------------------------------------------------------------- */
/* Fill one SPM payload row from initial Y                                    */
/* -------------------------------------------------------------------------- */

static void fill_y_row(
    uint32_t m0,
    uint32_t k0,
    uint32_t local_offset)
{
    uint32_t lane;

    for (lane = 0u; lane < SPM_FP16_PER_ROW; ++lane) {
        const uint32_t local = local_offset + lane;
        const uint32_t mi = local / TILE_K_SIZE;
        const uint32_t ki = local % TILE_K_SIZE;

        const uint32_t gm = m0 + mi;
        const uint32_t gk = k0 + ki;

        if ((gm < M_SIZE) && (gk < K_SIZE)) {
            spm_row[lane] = y_inp[gm * K_SIZE + gk];
        } else {
            spm_row[lane] = (_Float16)0.0f;
        }
    }
}

/* -------------------------------------------------------------------------- */
/* Write complete fixed-size tiles one SPM row at a time                      */
/* -------------------------------------------------------------------------- */

static uint32_t write_x_tile(
    uint32_t spm_addr,
    uint32_t m0,
    uint32_t n0)
{
    uint32_t local;

    for (local = 0u;
         local < X_TILE_ELEMS;
         local += SPM_FP16_PER_ROW) {

        fill_x_row(m0, n0, local);

        spm_addr = spm_load(
            spm_addr,
            (const uint32_t *)(const void *)&spm_row[0],
            SPM_PAYLOAD_WORDS);
    }

    return spm_addr;
}

static uint32_t write_w_tile(
    uint32_t spm_addr,
    uint32_t n0,
    uint32_t k0)
{
    uint32_t local;

    for (local = 0u;
         local < W_TILE_ELEMS;
         local += SPM_FP16_PER_ROW) {

        fill_w_row(n0, k0, local);

        spm_addr = spm_load(
            spm_addr,
            (const uint32_t *)(const void *)&spm_row[0],
            SPM_PAYLOAD_WORDS);
    }

    return spm_addr;
}

static uint32_t write_y_tile(
    uint32_t spm_addr,
    uint32_t m0,
    uint32_t k0)
{
    uint32_t local;

    for (local = 0u;
         local < Y_TILE_ELEMS;
         local += SPM_FP16_PER_ROW) {

        fill_y_row(m0, k0, local);

        spm_addr = spm_load(
            spm_addr,
            (const uint32_t *)(const void *)&spm_row[0],
            SPM_PAYLOAD_WORDS);
    }

    return spm_addr;
}

/* -------------------------------------------------------------------------- */
/* SPM upload                                                                 */
/* -------------------------------------------------------------------------- */

static void upload_first_reduction_tile(
    uint32_t slot,
    uint32_t hw_tile,
    uint32_t m0,
    uint32_t n0,
    uint32_t k0)
{
    uint32_t addr;

    isolde_set_tile(hw_tile);

    addr = get_addr_start(0);

    spm_layout[slot].x = addr;
    addr = write_x_tile(addr, m0, n0);

    spm_layout[slot].w = addr;
    addr = write_w_tile(addr, n0, k0);

    spm_layout[slot].y = addr;
    (void)write_y_tile(addr, m0, k0);
}

/*
 * Later reduction chunks overwrite only X and W.
 * Y remains untouched because it contains the accumulated partial result.
 */
static void upload_next_reduction_tile(
    uint32_t slot,
    uint32_t hw_tile,
    uint32_t m0,
    uint32_t n0,
    uint32_t k0)
{
    isolde_set_tile(hw_tile);

    (void)write_x_tile(
        spm_layout[slot].x,
        m0,
        n0);

    (void)write_w_tile(
        spm_layout[slot].w,
        n0,
        k0);
}

/* -------------------------------------------------------------------------- */
/* Read and validate one completed output tile                                */
/* -------------------------------------------------------------------------- */

static uint32_t check_output_tile(
    uint32_t slot,
    uint32_t hw_tile,
    uint32_t m0,
    uint32_t k0,
    uint32_t *worst_ulp)
{
    uint32_t spm_addr;
    uint32_t local;
    uint32_t errors = 0u;

    isolde_set_tile(hw_tile);
    spm_addr = spm_layout[slot].y;

    for (local = 0u;
         local < Y_TILE_ELEMS;
         local += SPM_FP16_PER_ROW) {

        uint32_t lane;

        spm_addr = spm_store(
            (uint32_t *)(void *)&spm_row[0],
            spm_addr,
            SPM_PAYLOAD_WORDS);

        for (lane = 0u; lane < SPM_FP16_PER_ROW; ++lane) {
            const uint32_t elem = local + lane;
            const uint32_t mi = elem / TILE_K_SIZE;
            const uint32_t ki = elem % TILE_K_SIZE;
            const uint32_t gm = m0 + mi;
            const uint32_t gk = k0 + ki;

            if ((gm < M_SIZE) && (gk < K_SIZE)) {
                const uint32_t global_idx = gm * K_SIZE + gk;
                const uint32_t ulp =
                    fp16_ulp_distance(
                        spm_row[lane],
                        golden[global_idx]);

                if (ulp > *worst_ulp) {
                    *worst_ulp = ulp;
                }

                if (ulp > GEMM_MAX_ULP_ERROR) {
                    if (errors < 8u) {
                        printf(
                            "[GEMM] mismatch Z[%d][%d] "
                            "got=0x%04x golden=0x%04x ulp=%d\n",
                            gm,
                            gk,
                            (uint32_t)fp16_bits(spm_row[lane]),
                            (uint32_t)fp16_bits(golden[global_idx]),
                            ulp);
                    }

                    ++errors;
                }
            }
        }
    }

    return errors;
}

/* -------------------------------------------------------------------------- */
/* Software-tiled GEMM                                                        */
/* -------------------------------------------------------------------------- */

static int run_tiled_gemm(uint32_t *error_count, uint32_t *worst_ulp)
{
    uint32_t hw_tiles = isolde_get_tile_cnt();
    uint32_t batch;

    *error_count = 0u;
    *worst_ulp = 0u;

    if (hw_tiles == 0u) {
        printf("[GEMM] ERROR: no RedMulE tiles available\n");
        return -1;
    }

    hw_tiles = min_u32(hw_tiles, MAX_HW_TILES);
    hw_tiles = min_u32(hw_tiles, 32u);

    printf("[GEMM] full problem:\n");
    printf("[GEMM]   X = %d x %d\n", M_SIZE, N_SIZE);
    printf("[GEMM]   W = %d x %d\n", N_SIZE, K_SIZE);
    printf("[GEMM]   Y/Z = %d x %d\n", M_SIZE, K_SIZE);

    printf("[GEMM] RedMulE software tile:\n");
    printf(
        "[GEMM]   X = %d x %d, W = %d x %d, Y = %d x %d\n",
        TILE_M_SIZE,
        TILE_N_SIZE,
        TILE_N_SIZE,
        TILE_K_SIZE,
        TILE_M_SIZE,
        TILE_K_SIZE);

    printf(
        "[GEMM] tile grid: M=%d reduction=%d K=%d, workers=%d\n",
        M_TILE_COUNT,
        N_TILE_COUNT,
        K_TILE_COUNT,
        hw_tiles);

    /*
     * Independent jobs are output tiles (M tile, K tile).
     * Up to hw_tiles independent output tiles are assigned to RedMulEs.
     */
    for (batch = 0u;
         batch < OUTPUT_TILE_COUNT;
         batch += hw_tiles) {

        const uint32_t active =
            min_u32(hw_tiles, OUTPUT_TILE_COUNT - batch);

        /*
         * These are tiny automatic arrays. They are CPU-only and therefore
         * may live on the separate stack.
         */
        uint32_t m0[MAX_HW_TILES];
        uint32_t k0[MAX_HW_TILES];

        uint32_t slot;
        uint32_t n_tile;

        for (slot = 0u; slot < active; ++slot) {
            const uint32_t output_id = batch + slot;
            const uint32_t mt = output_id / K_TILE_COUNT;
            const uint32_t kt = output_id % K_TILE_COUNT;

            m0[slot] = mt * TILE_M_SIZE;
            k0[slot] = kt * TILE_K_SIZE;
        }

        /*
         * Reduction over N.
         */
        for (n_tile = 0u;
             n_tile < N_TILE_COUNT;
             ++n_tile) {

            START_PERFCNT(n_tile)

            const uint32_t n0 =
                n_tile * TILE_N_SIZE;

            uint32_t tile_mask = 0u;

            /*
             * Tile packing is sequential because all workers share the single
             * loader channel and the single .bss row workspace. Accelerator
             * execution remains asynchronous across RedMulE tiles.
             */
            for (slot = 0u; slot < active; ++slot) {
                const uint32_t hw_tile = slot;

                if (n_tile == 0u) {
                    upload_first_reduction_tile(
                        slot,
                        hw_tile,
                        m0[slot],
                        n0,
                        k0[slot]);
                } else {
                    upload_next_reduction_tile(
                        slot,
                        hw_tile,
                        m0[slot],
                        n0,
                        k0[slot]);
                }

                /*
                 * RedMulE convention:
                 *
                 *   X[M x N] * W[N x K] + Y[M x K]
                 *
                 * BSP macro argument order:
                 *
                 *   K, M, N
                 */
                redmule_gemm_async(
                    hw_tile,
                    spm_layout[slot].x,
                    spm_layout[slot].w,
                    spm_layout[slot].y,
                    TILE_K_SIZE,
                    TILE_M_SIZE,
                    TILE_N_SIZE);

                tile_mask |= REDMULE_BIT(hw_tile);
            }

            /*
             * The next reduction chunk depends on the Y result of this one.
             */
            redmule_wait_all(tile_mask);

            STOP_PERFCNT(n_tile)
        }

        /*
         * Completed output tiles are read one row at a time and checked
         * directly against golden[]. No full z_result[] buffer is required.
         */
        for (slot = 0u; slot < active; ++slot) {
            const uint32_t hw_tile = slot;

            *error_count += check_output_tile(
                slot,
                hw_tile,
                m0[slot],
                k0[slot],
                worst_ulp);
        }
    }

    return 0;
}

/* -------------------------------------------------------------------------- */
/* main                                                                       */
/* -------------------------------------------------------------------------- */

int main(int argc, char **argv)
{
    uint32_t errors;
    uint32_t worst_ulp;

    (void)argc;
    (void)argv;

    print_system_info();

    printf("[GEMM] low-RAM SW-tiled RedMulE GEMM\n");

    /*
     * Tile completion indications are sticky/W1C.
     */
    isolde_clear_tile_ip((uint32_t)-1);

    if (run_tiled_gemm(&errors, &worst_ulp) != 0) {
        printf("[GEMM] execution failed\n");
        return 1;
    }

    printf(
        "[GEMM] validation: errors=%d worst_ulp=%d allowed_ulp=%d\n",
        errors,
        worst_ulp,
        (uint32_t)GEMM_MAX_ULP_ERROR);

    if (errors != 0u) {
        printf("[GEMM] FAILED\n");
        return 1;
    }

    printf("[GEMM] PASSED\n");
    return 0;
}