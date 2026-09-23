/* SPDX-License-Identifier: Apache-2.0 */
#include "tformer_runtime.h"
/* Which export to build against. The device build's include path puts
 * TEST_SRC_DIR/inc first and cannot be reordered from the command line, so the
 * configuration is chosen by file name rather than by -I ordering. */
#ifndef TF_WEIGHTS_HEADER
#define TF_WEIGHTS_HEADER "tformer_weights.h"
#endif
#include TF_WEIGHTS_HEADER
#include <bsp/onnx_redmule_runtime.h>

enum { TILES = 3, TILE_MASK = 0x7u,
       ROWS = 12, COLS = 16,
       X_ELEMENTS = ROWS * COLS,        /* 192, the 12x16 operand and result */
       W_ELEMENTS = COLS * COLS,        /* 256, the 16x16 operand */
       FF_TILES = TF_DFF / COLS,
       FF_MASK = (1u << FF_TILES) - 1u };

_Static_assert(TF_FRAMES == ROWS, "the window must be one tile tall");
_Static_assert(TF_DMODEL == COLS, "d_model must be one tile wide");
_Static_assert(TF_FEATURES == 2u * COLS, "the projection assumes two K-tiles");
_Static_assert(TF_DFF % COLS == 0u, "d_ff must be a whole number of tiles");
_Static_assert(FF_TILES <= TILES, "one MLP N-tile per RedMulE, no reuse");
_Static_assert(TF_CLASSES <= COLS, "the classifier head is one tile");

/* There is no SPM-to-SPM copy in the runtime ABI, so every intermediate goes
 * SPM -> DMEM -> SPM.  These are the DMEM staging buffers.
 */
static uint16_t h[X_ELEMENTS];
static uint16_t qq[X_ELEMENTS], kk[X_ELEMENTS], vv[X_ELEMENTS];
static uint16_t ss[X_ELEMENTS], oo[X_ELEMENTS], pooled[X_ELEMENTS];
static uint16_t square_a[W_ELEMENTS], square_b[W_ELEMENTS];
static uint16_t ff[FF_TILES][X_ELEMENTS];

typedef struct { uint32_t x, w, y; } layout_t;
static layout_t spm[TILES];
static uint8_t placed[TILES];

/* Upload the two read-only operands into this tile's fixed slots.  The first
 * call for a tile also fixes the cursors, exactly as beamform_runtime3 does.
 */
static void stage(uint32_t tile, const uint16_t *x, const uint16_t *w)
{
  if (!placed[tile]) {
    spm[tile].x = omrm_addr_start(tile, 0);
    spm[tile].w = omrm_upload_f16(tile, spm[tile].x, x, X_ELEMENTS, 0);
    spm[tile].y = omrm_upload_f16(tile, spm[tile].w, w, W_ELEMENTS, 0);
    placed[tile] = 1;
    return;
  }
  omrm_upload_f16(tile, spm[tile].x, x, X_ELEMENTS, 0);
  omrm_upload_f16(tile, spm[tile].w, w, W_ELEMENTS, 0);
}

static void launch_zero(uint32_t tile, const uint16_t *x, const uint16_t *w)
{
  stage(tile, x, w);
  omrm_zero_f16(tile, spm[tile].y, X_ELEMENTS);
  omrm_gemm_f16_16_12_16(tile, spm[tile].x, spm[tile].w, spm[tile].y);
}

/* Z = X.W + Y with Y preloaded: this is how a residual costs nothing. */
static void launch_bias(uint32_t tile, const uint16_t *x, const uint16_t *w,
                        const uint16_t *y)
{
  stage(tile, x, w);
  omrm_upload_f16(tile, spm[tile].y, y, X_ELEMENTS, 0);
  omrm_gemm_f16_16_12_16(tile, spm[tile].x, spm[tile].w, spm[tile].y);
}

/* Leave Y untouched, so a K-reduction accumulates across launches. */
static void launch_accumulate(uint32_t tile, const uint16_t *x,
                              const uint16_t *w)
{
  stage(tile, x, w);
  omrm_gemm_f16_16_12_16(tile, spm[tile].x, spm[tile].w, spm[tile].y);
}

static void collect(uint32_t tile, uint16_t *destination)
{
  omrm_download_f16(tile, spm[tile].y, destination, X_ELEMENTS);
}

/* ReLU on binary16: anything with the sign bit set becomes +0. */
static void relu(uint16_t *values, uint32_t count)
{
  uint32_t i;
  for (i = 0; i < count; ++i)
    values[i] = (uint16_t)(values[i] & 0x8000u ? 0u : values[i]);
}

/* K^T as a 16x16 W operand: columns 12..15 are zero, so the scores in those
 * columns are zero and survive ReLU as zero, contributing nothing to A.V.
 */
static void transpose_pad(uint16_t *destination, const uint16_t *source)
{
  uint32_t row, col;
  for (row = 0; row < COLS; ++row)
    for (col = 0; col < COLS; ++col)
      destination[row * COLS + col] =
          col < ROWS ? source[col * COLS + row] : 0u;
}

/* A 12x16 result reused as a 16x16 W operand: pad the last four rows. */
static void rows_pad(uint16_t *destination, const uint16_t *source)
{
  uint32_t i;
  for (i = 0; i < ROWS * COLS; ++i) destination[i] = source[i];
  for (i = ROWS * COLS; i < W_ELEMENTS; ++i) destination[i] = 0u;
}

void tformer_runtime3(const uint16_t *window, uint16_t *logits)
{
  uint32_t layer, t;

  /* Projection, two K-tiles.  The positional embedding is the Y preload of
   * the first, so it costs no separate pass.
   */
  launch_bias(0, window, tf_proj, tf_pos);
  omrm_wait(1u);
  launch_accumulate(0, window + X_ELEMENTS, tf_proj + W_ELEMENTS);
  omrm_wait(1u);
  collect(0, h);

  for (layer = 0; layer < TF_LAYERS; ++layer) {
    const uint16_t *const *w = tf_layer[layer];

    /* Q, K and V are independent: one per RedMulE, a single barrier. */
    launch_zero(0, h, w[TF_WQ]);
    launch_zero(1, h, w[TF_WK]);
    launch_zero(2, h, w[TF_WV]);
    omrm_wait(TILE_MASK);
    collect(0, qq);
    collect(1, kk);
    collect(2, vv);

    /* Scores.  1/sqrt(d_model) is already folded into Wq. */
    transpose_pad(square_a, kk);
    launch_zero(0, qq, square_a);
    omrm_wait(1u);
    collect(0, ss);

    /* ReLU-attention: no softmax, so no exponential and no division.
     * The 1/L normalisation is folded into Wv.
     */
    relu(ss, X_ELEMENTS);

    rows_pad(square_b, vv);
    launch_zero(0, ss, square_b);
    omrm_wait(1u);
    collect(0, oo);

    /* Residual rides the accumulator: H = O.Wo + H in one launch. */
    launch_bias(0, oo, w[TF_WO], h);
    omrm_wait(1u);
    collect(0, h);

    /* MLP up is an N-split, so the three tiles run it in parallel. */
    for (t = 0; t < FF_TILES; ++t)
      launch_zero(t, h, w[TF_W1] + t * W_ELEMENTS);
    omrm_wait(FF_MASK);
    for (t = 0; t < FF_TILES; ++t) {
      collect(t, ff[t]);
      relu(ff[t], X_ELEMENTS);
    }

    /* MLP down is a K-reduction into one accumulator, so it serialises on a
     * single tile.  This is the one stage where the extra tiles do not help.
     */
    launch_bias(0, ff[0], w[TF_W2], h);
    omrm_wait(1u);
    for (t = 1; t < FF_TILES; ++t) {
      launch_accumulate(0, ff[t], w[TF_W2] + t * W_ELEMENTS);
      omrm_wait(1u);
    }
    collect(0, h);
  }

  /* Mean over frames as a GEMM against a constant 1/12 matrix; every output
   * row is the same mean, so the classifier only needs row 0.
   */
  rows_pad(square_a, h);
  launch_zero(0, tf_pool, square_a);
  omrm_wait(1u);
  collect(0, pooled);

  launch_zero(0, pooled, tf_head);
  omrm_wait(1u);
  collect(0, square_b);
  for (t = 0; t < TF_CLASSES; ++t) logits[t] = square_b[t];
}

uint32_t tf_argmax(const uint16_t *logits, uint32_t count)
{
  uint32_t i, best = 0, best_key = 0;
  for (i = 0; i < count; ++i) {
    /* Map binary16 bits to an unsigned key that orders like the float. */
    uint32_t key = logits[i] & 0x8000u ? 0x8000u - (logits[i] & 0x7fffu)
                                       : 0x8000u + logits[i];
    if (i == 0 || key > best_key) {
      best_key = key;
      best = i;
    }
  }
  return best;
}
