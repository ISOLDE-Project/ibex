#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include "beamform_scaling.h"
#include "inc/radar_vectors.h"

extern unsigned mock_launches[3], mock_waits, mock_masks[12];
void mock_reset(void);
struct guarded { uint16_t before, data[BF_M * BF_K], after; };
static struct guarded cr, ci;

int main(void)
{
  const unsigned order[] = {1, 2, 3, 2, 1, 3};
  for (unsigned pass = 0; pass < sizeof order / sizeof order[0]; ++pass) {
    unsigned instances = order[pass];
    mock_reset();
    cr.before = ci.before = 0x1234;
    cr.after = ci.after = 0xabcd;
    for (unsigned i = 0; i < BF_M * BF_K; ++i) cr.data[i] = ci.data[i] = 0x7e00;
    assert(beamform_scaling(instances, bf_ar, bf_ai, bf_br, bf_bi, cr.data, ci.data) == 0);
    for (unsigned i = 0; i < BF_M * BF_K; ++i) {
      assert(cr.data[i] == bf_cr_golden[i] || ((cr.data[i] | bf_cr_golden[i]) & 0x7fff) == 0);
      assert(ci.data[i] == bf_ci_golden[i] || ((ci.data[i] | bf_ci_golden[i]) & 0x7fff) == 0);
    }
    assert(cr.before == 0x1234 && ci.before == 0x1234);
    assert(cr.after == 0xabcd && ci.after == 0xabcd);
    assert(mock_launches[0] + mock_launches[1] + mock_launches[2] == 12);
    assert(mock_waits == 4 * ((3 + instances - 1) / instances));
    for (unsigned wave = 0; wave < mock_waits; ++wave) {
      unsigned expected = instances == 1 ? 1 : instances == 3 ? 7 : wave < 4 ? 3 : 1;
      assert(mock_masks[wave] == expected);
    }
    assert(mock_launches[0] == (instances == 1 ? 12 : instances == 2 ? 8 : 4));
    assert(mock_launches[1] == (instances == 1 ? 0 : 4));
    assert(mock_launches[2] == (instances == 3 ? 4 : 0));
  }
  mock_reset();
  assert(beamform_scaling(0, 0, 0, 0, 0, 0, 0) == -1);
  assert(beamform_scaling(4, 0, 0, 0, 0, 0, 0) == -1);
  assert(mock_waits == 0 && mock_launches[0] == 0);
  puts("PASS: 1/2/3-instance schedules, outputs, tails, guards, and stale-state checks");
  return 0;
}
