/* SPDX-License-Identifier: Apache-2.0 */
#include "tformer_features.h"

#define TF_SIGN_MASK 0x8000u
#define TF_ABS_MASK  0x7fffu

/* max(|Cr|, |Ci|): clear the sign bit, then an unsigned compare.
 * Under-reads a true magnitude by at most 3 dB and never over-reads.
 */
static uint16_t magnitude(uint16_t cr, uint16_t ci)
{
  uint16_t a = (uint16_t)(cr & TF_ABS_MASK);
  uint16_t b = (uint16_t)(ci & TF_ABS_MASK);
  return a > b ? a : b;
}

void tf_frame_profiles(const uint16_t *cr, const uint16_t *ci,
                       uint16_t *bearing, uint16_t *range)
{
  uint32_t beam, bin, group;
  uint16_t per_beam[TF_BEAMS];

  for (bin = 0; bin < TF_RANGE_BINS; ++bin) range[bin] = 0;

  for (beam = 0; beam < TF_BEAMS; ++beam) {
    uint16_t best = 0;
    for (bin = 0; bin < TF_RANGE_BINS; ++bin) {
      uint32_t index = beam * TF_RANGE_BINS + bin;
      uint16_t value = magnitude(cr[index], ci[index]);
      if (value > best) best = value;
      if (value > range[bin]) range[bin] = value;
    }
    per_beam[beam] = best;
  }

  /* 36 beams into 16 groups of two or three, by the generated edge table. */
  for (group = 0; group < TF_ANGLE_GROUPS; ++group) {
    uint16_t best = 0;
    for (beam = tf_angle_group_edge[group];
         beam < tf_angle_group_edge[group + 1]; ++beam)
      if (per_beam[beam] > best) best = per_beam[beam];
    bearing[group] = best;
  }
}

/* Binary16 bit pattern of count * 2^-TF_LOG_SCALE_SHIFT, exactly.
 *
 * `count` is at most 2048, so it has at most 12 significant bits and the
 * result always lands in the normal range. No rounding occurs, which is why
 * the C and the Python reference agree bit for bit rather than approximately.
 */
static uint16_t scaled_half(uint32_t count)
{
  uint32_t exponent, mantissa;
  if (count == 0u) return 0u;
  exponent = 31u - (uint32_t)__builtin_clz(count);      /* floor(log2(count)) */
  mantissa = exponent <= 10u ? (count << (10u - exponent)) & 0x3ffu
                             : (count >> (exponent - 10u)) & 0x3ffu;
  return (uint16_t)(((exponent + 15u - TF_LOG_SCALE_SHIFT) << 10) | mantissa);
}

/* Both feature planes are 16 wide, which is what makes each one a single
 * RedMulE X operand. The front end's shape depends on that. */
_Static_assert(TF_ANGLE_GROUPS == 16u, "bearing plane must be one tile wide");
_Static_assert(TF_RANGE_BINS == 16u, "range plane must be one tile wide");

void tf_normalise_window(uint16_t *window, uint32_t frames)
{
  uint32_t total = 2u * frames * 16u, i;
  int32_t peak = -32768;                 /* below every table entry */

  /* Two passes over the window: the peak is over the whole sequence, so a
   * per-frame normalisation would lose the amplitude trend between frames.
   */
  for (i = 0; i < total; ++i) {
    int32_t value = tf_log2_lut[window[i] >> TF_LOG2_LUT_SHIFT];
    if (value > peak) peak = value;
  }
  for (i = 0; i < total; ++i) {
    int32_t value = tf_log2_lut[window[i] >> TF_LOG2_LUT_SHIFT] - peak;
    if (value < TF_LOG_FLOOR_Q) value = TF_LOG_FLOOR_Q;
    if (value > 0) value = 0;
    window[i] = scaled_half((uint32_t)(value - TF_LOG_FLOOR_Q));
  }
}
