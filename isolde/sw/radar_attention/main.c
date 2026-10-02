/* SPDX-License-Identifier: Apache-2.0 */
#include <stdint.h>
#include <string.h>
#include <bsp/omp_redmule.h>
#include <bsp/platform.h>
/* First: TF_DFF sizes the runtime's scratch budget. */
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
#if TF_CHAIN
#include "beamform_runtime.h"
#endif

#ifndef TF_DUMP
#define TF_DUMP 1
#endif
/* Chain mode only: dump this frame's range-angle map so the viewer can show
 * the radar picture next to the features. -1 dumps none. 1152 extra lines. */
#ifndef TF_DUMP_MAP
#define TF_DUMP_MAP (-1)
#endif
/* Room left for the BSP's own globals; override if the map says otherwise. */
#ifndef TF_DMEM_RESERVE
#define TF_DMEM_RESERVE 1024u
#endif
#ifndef TF_DMEM_BYTES
/* dataram size of the platform in isolde/config/jobs.yml */
#define TF_DMEM_BYTES PLATFORM_DATARAM_LENGTH
#endif

#define TF_WINDOW_ELEMENTS (2u * TF_FRAMES * 16u)

static uint16_t window[TF_WINDOW_ELEMENTS] __attribute__((aligned(16)));
static uint16_t logits[TF_CLASSES];

/* The input case: tf_features and tf_logits_golden from the generated headers,
 * plus these two. `make cases` writes a replacement for all four as one ihex,
 * which OpenOCD's load_image puts in dataram before the core starts
 * (jtag_upload.tcl: upload radar_attention <class>). All four are read through
 * volatile, so the firmware uses what is in RAM, not what the compiler saw. */
/* Not static: clang merges a static copy with the identical string literal
 * and the symbol disappears from the ELF, where tformer_case.py looks for it. */
const volatile char tf_case_id[17] = TF_CASE_ID;
const volatile uint32_t tf_true_class = TF_TRUE_CLASS;
#define TF_CASE_FEATURES ((const volatile uint16_t *)tf_features)
#define TF_CASE_GOLDEN ((const volatile uint16_t *)tf_logits_golden)

#if TF_CHAIN
static uint16_t cr[TF_BEAMS * TF_RANGE_BINS] __attribute__((aligned(16)));
static uint16_t ci[TF_BEAMS * TF_RANGE_BINS] __attribute__((aligned(16)));
#define TF_CHAIN_BYTES (sizeof cr + sizeof ci + sizeof tf_ar + sizeof tf_ai \
                        + sizeof tf_br + sizeof tf_bi)
#else
#define TF_CHAIN_BYTES 0u
#endif

/* Everything this application places in dataram, weights included.  The
 * runtime's own staging buffers are counted through tf_runtime_dmem_bytes().
 * If this fires, the honest fixes are `tformer.py --layers 1` or a platform
 * with more dataram; see the README's memory section.
 */
#define TF_STATIC_BYTES (sizeof window + sizeof logits + sizeof tf_features \
                         + sizeof tf_logits_golden + TF_CHAIN_BYTES \
                         + TF_WEIGHT_BYTES + TF_RUNTIME_SCRATCH_BYTES)
_Static_assert(TF_STATIC_BYTES + TF_DMEM_RESERVE <= TF_DMEM_BYTES,
               "application data exceeds dataram; see the README");

static uint32_t ordered(uint16_t bits)
{
  return bits & 0x8000u ? 0x8000u - (bits & 0x7fffu) : 0x8000u + bits;
}

static uint32_t compare(const uint16_t *actual, const uint16_t *golden,
                        uint32_t count, const char *name, uint32_t *worst)
{
  uint32_t i, errors = 0;
  for (i = 0; i < count; ++i) {
    uint32_t a = ordered(actual[i]), g = ordered(golden[i]);
    uint32_t ulp = a > g ? a - g : g - a;
    if (ulp > *worst) *worst = ulp;
    if (ulp > MAX_TF_ULP) {
      if (errors < 6u)
        printf("[TFORMER] %s[%u] got=%04x expected=%04x ulp=%u\n", name, i,
               (unsigned)actual[i], (unsigned)golden[i], ulp);
      ++errors;
    }
  }
  return errors;
}

#if TF_CHAIN
/* One firmware run: the beamformer feeds the encoder.  Each frame is an
 * independent 36-beam scan; only the 32 features survive into the window.
 */
static void sense_window(void)
{
  uint32_t frame;
  for (frame = 0; frame < TF_FRAMES; ++frame) {
    const uint32_t snapshot = frame * TF_ANTENNAS * TF_RANGE_BINS;
    beamform_runtime3(tf_ar, tf_ai, tf_br + snapshot, tf_bi + snapshot, cr, ci);
    if ((int)frame == (TF_DUMP_MAP)) {
      uint32_t j;
      printf("[TFMAPHDR] frame=%u beams=%u bins=%u\n", frame, TF_BEAMS,
             TF_RANGE_BINS);
      for (j = 0; j < TF_BEAMS * TF_RANGE_BINS; ++j)
        printf("[TFMAP] %u %04x %04x\n", j, (unsigned)cr[j], (unsigned)ci[j]);
    }
    tf_frame_profiles(cr, ci,
                      window + frame * 16u,                     /* bearing */
                      window + (TF_FRAMES + frame) * 16u);      /* range   */
  }
  tf_normalise_window(window, TF_FRAMES);
}
#endif

int main(void)
{
  uint32_t errors = 0, worst = 0, predicted, expected, true_class, i;
  uint16_t golden[TF_CLASSES];
  char case_id[sizeof tf_case_id];

  for (i = 0; i + 1u < sizeof case_id; ++i) case_id[i] = tf_case_id[i];
  case_id[sizeof case_id - 1u] = '\0';
  for (i = 0; i < TF_CLASSES; ++i) golden[i] = TF_CASE_GOLDEN[i];
  expected = tf_argmax(golden, TF_CLASSES);
  true_class = tf_true_class < TF_CLASSES ? tf_true_class : 0u;

  printf("[TFORMER] case=%s weights=%s mode=%s\n", case_id, TF_WEIGHTS_ID,
         TF_CHAIN ? "chain" : "encoder");
  printf("[TFORMER] frames=%u features=%u d_model=%u d_ff=%u layers=%u\n",
         TF_FRAMES, TF_FEATURES, TF_DMODEL, TF_DFF, TF_LAYERS);
  printf("[TFORMER] launches=%u barriers=%u\n", TF_LAUNCHES, TF_BARRIERS);

  /* The weights header carries this model's goldens and the vectors header
   * carries the data case. A stale pair compares correct outputs against the
   * wrong answers, which looks like an RTL fault, so refuse to run. */
  if (strcmp(TF_CASE_ID, TF_GOLDEN_CASE_ID) != 0) {
    printf("[TFORMER] FAILED vectors case=%s but goldens were exported for "
           "case=%s; re-run make model\n", TF_CASE_ID, TF_GOLDEN_CASE_ID);
    return 1;
  }

  if (isolde_get_tile_cnt() < 3u) {
    printf("[TFORMER] FAILED insufficient RedMulE tiles\n");
    return 1;
  }
  isolde_clear_tile_ip(0x7u);

  START_PERFCNT(0x1)
#if TF_CHAIN
  sense_window();
#else
  for (i = 0; i < TF_WINDOW_ELEMENTS; ++i) window[i] = TF_CASE_FEATURES[i];
#endif
  STOP_PERFCNT(0x1)
#if TF_CHAIN
  /* The front end must reproduce the exported features bit for bit: it is
   * integer work, so any difference is a bug, not rounding. */
  for (i = 0; i < TF_WINDOW_ELEMENTS; ++i)
    if (window[i] != tf_features[i]) {
      if (errors < 6u)
        printf("[TFORMER] feature[%u] got=%04x expected=%04x\n", i,
               (unsigned)window[i], (unsigned)tf_features[i]);
      ++errors;
    }
  printf("[TFORMER] feature_errors=%u (exact match required)\n", errors);
#endif

  START_PERFCNT(0x2)
  tformer_runtime3(window, logits);
  STOP_PERFCNT(0x2)
  printPerfCnt();

  errors += compare(logits, golden, TF_CLASSES, "logit", &worst);
  predicted = tf_argmax(logits, TF_CLASSES);

#if TF_DUMP
  for (i = 0; i < TF_WINDOW_ELEMENTS; ++i)
    printf("[TFWIN] %u %04x\n", i, (unsigned)window[i]);
  for (i = 0; i < TF_CLASSES; ++i)
    printf("[TFLOG] %u %04x\n", i, (unsigned)logits[i]);
#endif

  printf("[TFORMER] class=%s expected=%s true=%s\n",
         tf_class_name[predicted], tf_class_name[expected],
         tf_class_name[true_class]);
  if (predicted != expected) {
    printf("[TFORMER] FAILED class mismatch\n");
    ++errors;
  }
  printf("[TFORMER] errors=%u worst_ulp=%u (tolerance %u)\n", errors, worst,
         MAX_TF_ULP);
  printf("[TFORMER] %s\n", errors ? "FAILED" : "PASSED");
  return errors ? 1 : 0;
}
