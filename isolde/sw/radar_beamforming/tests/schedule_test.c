#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include "beamform_runtime.h"
#include "radar_vectors.h"
extern unsigned mock_launches, mock_waits;
static uint16_t cr[BF_M*BF_K], ci[BF_M*BF_K];
int main(void)
{
  /* Run twice to catch stale SPM accumulator state across invocations. */
  for (unsigned pass = 0; pass < 2; ++pass) {
    beamform_runtime3(bf_ar, bf_ai, bf_br, bf_bi, cr, ci);
    for (unsigned i = 0; i < BF_M*BF_K; ++i) {
      assert(cr[i] == bf_cr_golden[i] || ((cr[i] | bf_cr_golden[i]) & 0x7fff) == 0);
      assert(ci[i] == bf_ci_golden[i] || ((ci[i] | bf_ci_golden[i]) & 0x7fff) == 0);
    }
  }
  assert(mock_launches == 24 && mock_waits == 8);
  puts("Host scheduling test PASSED: 2 scans, 24 launches, 8 three-tile barriers.");
  return 0;
}
