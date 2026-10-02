/* Scheduling and numerics of tformer_runtime3 against the host mock. */
#include <assert.h>
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
#include "tformer_vectors.h"

extern unsigned mock_launches, mock_waits, mock_uploads, mock_downloads;
extern unsigned mock_max_cursor;
extern void mock_reset(void);

#define WINDOW_ELEMENTS (2u * TF_FRAMES * 16u)

static uint16_t window[WINDOW_ELEMENTS];
static uint16_t logits[TF_CLASSES];

int main(void)
{
  unsigned pass, i;

  /* Twice, to catch an accumulator or SPM cursor left dirty by the first. */
  for (pass = 0; pass < 2; ++pass) {
    mock_reset();
    for (i = 0; i < WINDOW_ELEMENTS; ++i) window[i] = tf_features[i];
    for (i = 0; i < TF_CLASSES; ++i) logits[i] = 0xdead;

    tformer_runtime3(window, logits);

    /* The mock and the Python reference run identical arithmetic, so the
     * agreement here is exact. Any ULP at all would be a real difference. */
    for (i = 0; i < TF_CLASSES; ++i)
      assert(logits[i] == tf_logits_golden[i]);
    assert(tf_argmax(logits, TF_CLASSES) == TF_PREDICTED_CLASS);

    /* The schedule must cost exactly what the exporter derived from the
     * model's shape; a stray launch or a missing barrier changes these. */
    assert(mock_launches == TF_LAUNCHES);
    assert(mock_waits == TF_BARRIERS);

    /* Every launch stages X and W; only Y preloads add uploads. */
    assert(mock_uploads >= 2u * TF_LAUNCHES);
    assert(mock_downloads > 0u);
  }

  /* The three fixed slots span 2560 bytes per tile, as in radar_beamforming.
   * Growing past that would mean the SPM layout silently changed. */
  assert(mock_max_cursor < 2560u);

  printf("Host scheduling test PASSED: 2 passes, %u launches, %u barriers, "
         "%u uploads, %u downloads, SPM cursor < %u bytes.\n",
         mock_launches, mock_waits, mock_uploads, mock_downloads, 2560u);
  return 0;
}
