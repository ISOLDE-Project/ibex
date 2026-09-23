/* SPDX-License-Identifier: Apache-2.0
 *
 * Three-tile schedule for the radar_attention encoder.
 *
 * Fixed ABI: `window` is [2][TF_FRAMES][16] binary16, plane 0 the bearing
 * features and plane 1 the range features; `logits` receives TF_CLASSES
 * values.  The caller owns both buffers and must provide three RedMulE tiles.
 * This routine performs no CPU floating point: the only non-GEMM work is a
 * sign-bit mask (ReLU) and uint16 moves (transpose, zero padding).
 */
#ifndef TFORMER_RUNTIME_H
#define TFORMER_RUNTIME_H

#include <stdint.h>

/* Column order of the per-layer weight pointer table in tformer_weights.h. */
enum { TF_WQ = 0, TF_WK, TF_WV, TF_WO, TF_W1, TF_W2 };

/* The host mock and the FP16 reference use identical arithmetic, so on the
 * host this must be 0. It is nonzero only to leave room for RTL differences.
 */
#ifndef MAX_TF_ULP
#define MAX_TF_ULP 4u
#endif

/* DMEM the runtime stages intermediates in. Needs TF_DFF, so include
 * tformer_weights.h first if you want to budget against it.
 */
#ifdef TF_DFF
#define TF_RUNTIME_SCRATCH_BYTES \
  ((7u * 192u + 2u * 256u + (TF_DFF / 16u) * 192u) * 2u)
#endif

void tformer_runtime3(const uint16_t *window, uint16_t *logits);

/* Index of the largest logit, by unsigned compare on the monotonic ordering
 * of binary16 bit patterns.  No floating point, and correct for negatives.
 */
uint32_t tf_argmax(const uint16_t *logits, uint32_t count);

#endif /* TFORMER_RUNTIME_H */
