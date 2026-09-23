/* Prints what this configuration would place in dataram.
 *
 * main.c carries the same arithmetic as a _Static_assert, so an over-budget
 * build fails rather than silently overflowing. This prints the numbers that
 * assert cannot, which is what you want when deciding what to cut.
 */
#include <stdint.h>
#include <stdio.h>
/* Which export to build against. The device build's include path puts
 * TEST_SRC_DIR/inc first and cannot be reordered from the command line, so the
 * configuration is chosen by file name rather than by -I ordering. */
#ifndef TF_WEIGHTS_HEADER
#define TF_WEIGHTS_HEADER "tformer_weights.h"
#endif
#include TF_WEIGHTS_HEADER
#include "tformer_runtime.h"
#include "tformer_features.h"
#include "tformer_vectors.h"

#ifndef TF_DMEM_BYTES
#define TF_DMEM_BYTES 32768u
#endif
#ifndef TF_DMEM_RESERVE
#define TF_DMEM_RESERVE 1024u
#endif

int main(void)
{
  unsigned window = 2u * TF_FRAMES * 16u * 2u;
  unsigned vectors = (unsigned)(sizeof tf_features + sizeof tf_logits_golden);
  unsigned chain = 0;
  unsigned total;

#if TF_CHAIN
  chain = (unsigned)(sizeof tf_ar + sizeof tf_ai + sizeof tf_br + sizeof tf_bi)
          + 2u * TF_BEAMS * TF_RANGE_BINS * 2u;
#endif
  total = window + vectors + chain + TF_WEIGHT_BYTES
          + TF_RUNTIME_SCRATCH_BYTES + TF_CLASSES * 2u;

  printf("mode                  %s\n", TF_CHAIN ? "chain" : "encoder");
  printf("layers                %u\n", TF_LAYERS);
  printf("weights               %6u B\n", TF_WEIGHT_BYTES);
  printf("runtime scratch       %6u B\n", TF_RUNTIME_SCRATCH_BYTES);
  printf("feature window        %6u B\n", window);
  printf("golden vectors        %6u B\n", vectors);
  printf("chain input + maps    %6u B\n", chain);
  printf("----------------------------\n");
  printf("total                 %6u B\n", total);
  printf("reserve               %6u B\n", (unsigned)TF_DMEM_RESERVE);
  printf("dataram               %6u B\n", (unsigned)TF_DMEM_BYTES);
  printf("headroom              %6d B\n",
         (int)TF_DMEM_BYTES - (int)total - (int)TF_DMEM_RESERVE);
  return 0;
}
