/* Exercises the feature front end from stdin so Python can drive it with
 * cases the exported vectors do not contain: zeros, a single peak, the full
 * dynamic range, saturation at the floor.
 *
 *   feature_test profiles   < 2*36*16 hex words (cr then ci) > 32 hex words
 *   feature_test normalise  < 2*F*16  hex words             > the same count
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "tformer_features.h"

#define MAX_WORDS 4096

static uint16_t input[MAX_WORDS];

static uint32_t read_words(void)
{
  uint32_t count = 0;
  unsigned value;
  while (count < MAX_WORDS && scanf("%x", &value) == 1)
    input[count++] = (uint16_t)value;
  return count;
}

int main(int argc, char **argv)
{
  uint32_t count = read_words(), i;
  if (argc != 2) return 2;

  if (!strcmp(argv[1], "profiles")) {
    uint16_t bearing[16], range[16];
    if (count != 2u * TF_BEAMS * TF_RANGE_BINS) return 3;
    tf_frame_profiles(input, input + TF_BEAMS * TF_RANGE_BINS, bearing, range);
    for (i = 0; i < 16; ++i) printf("%04x\n", bearing[i]);
    for (i = 0; i < 16; ++i) printf("%04x\n", range[i]);
    return 0;
  }

  if (!strcmp(argv[1], "normalise")) {
    if (count == 0 || count % 32u) return 3;
    tf_normalise_window(input, count / 32u);
    for (i = 0; i < count; ++i) printf("%04x\n", input[i]);
    return 0;
  }
  return 2;
}
