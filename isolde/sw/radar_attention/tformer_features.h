/* SPDX-License-Identifier: Apache-2.0
 *
 * Beamformer output -> encoder input, with no CPU floating point.
 *
 * Every operation below is a sign-bit mask, an unsigned 16-bit compare, a
 * table index or a shift.  For non-negative binary16 the unsigned integer
 * order equals the float order, which is what makes the compares legal.
 */
#ifndef TFORMER_FEATURES_H
#define TFORMER_FEATURES_H

#include <stdint.h>
#include "tformer_features_const.h"

/* One frame: the 36x16 split-complex map collapses to a 16-value bearing
 * profile and a 16-value range profile, both still linear binary16 bits.
 * `cr` and `ci` are beam-major, exactly as beamform_runtime3 leaves them.
 */
void tf_frame_profiles(const uint16_t *cr, const uint16_t *ci,
                       uint16_t *bearing, uint16_t *range);

/* The whole window, in place: Q8.8 log2 by table, subtract the peak over all
 * 2*frames*16 values, clamp at TF_LOG_FLOOR_Q, rescale by 2^-11.  `window` is
 * [2][frames][16]: plane 0 bearing, plane 1 range, which is the pair of X
 * operands the projection's two K-tiles consume.
 */
void tf_normalise_window(uint16_t *window, uint32_t frames);

#endif /* TFORMER_FEATURES_H */
