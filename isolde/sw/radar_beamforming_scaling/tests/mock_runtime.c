/* Host software model adapted from the original radar_beamforming test.
 * Deferred GEMMs detect missing barriers and in-flight overwrites. This does
 * NOT emulate XIF, the loader, event delivery, RTL, or accelerator timing.
 */
#include <assert.h>
#include <stdint.h>
#include <string.h>
#include <bsp/onnx_redmule_runtime.h>

static uint16_t spm[3][4096];
static uint32_t pending, jobs[3][3];
unsigned mock_launches[3], mock_waits, mock_masks[12];

void mock_reset(void)
{
  assert(pending == 0);
  memset(mock_launches, 0, sizeof mock_launches);
  memset(mock_masks, 0, sizeof mock_masks);
  mock_waits = 0;
  /* Leave SPM unchanged to expose stale accumulators across calls. */
}
static int mock_timing;
void bf_mock_bench_start(void)
{
  assert(!mock_timing);
  mock_timing = 1;
}
uint32_t bf_mock_bench_stop(void)
{
  assert(mock_timing);
  mock_timing = 0;
  /* Synthetic timing only; high bit verifies unsigned UART formatting. */
  return UINT32_C(0x8000007b);
}
static uint16_t *element(uint32_t tile, uint32_t addr, uint32_t i)
{
  uint32_t index = addr / 2 + (i / 16) * 32 + i % 16;
  assert(tile < 3 && addr % 64 == 0 && index < 4096);
  return &spm[tile][index];
}
static float value(uint16_t bits)
{
  _Float16 half;
  memcpy(&half, &bits, 2);
  return (float)half;
}
static uint16_t bits(float value)
{
  _Float16 half = (_Float16)value;
  uint16_t result;
  memcpy(&result, &half, 2);
  return result;
}
uint32_t omrm_addr_start(uint32_t tile, uint32_t bank)
{
  assert(tile < 3 && bank == 0);
  return 0;
}
uint32_t omrm_upload_f16(uint32_t tile, uint32_t addr, const void *src,
                         uint32_t elements, uint32_t negate)
{
  assert(tile < 3 && !(pending & (1u << tile)));
  assert(elements % 16 == 0 && negate <= 1);
  for (uint32_t i = 0; i < elements; ++i)
    *element(tile, addr, i) = ((const uint16_t *)src)[i] ^ (negate ? 0x8000u : 0);
  return addr + (elements / 16) * 64;
}
void omrm_zero_f16(uint32_t tile, uint32_t addr, uint32_t elements)
{
  assert(tile < 3 && !(pending & (1u << tile)) && elements == 192);
  for (uint32_t i = 0; i < elements; ++i) *element(tile, addr, i) = 0;
}
void omrm_gemm_f16_16_12_16(uint32_t tile, uint32_t x, uint32_t w, uint32_t y)
{
  assert(tile < 3 && !(pending & (1u << tile)));
  assert(x == 0 && w == 768 && y == 1792);
  jobs[tile][0] = x; jobs[tile][1] = w; jobs[tile][2] = y;
  pending |= 1u << tile;
  ++mock_launches[tile];
}
void omrm_wait(uint32_t mask)
{
  assert((mask == 1 || mask == 3 || mask == 7) && pending == mask);
  if (mock_waits < 12) mock_masks[mock_waits] = mask;
  ++mock_waits;
  for (unsigned tile = 0; tile < 3; ++tile) {
    if (!(mask & (1u << tile))) continue;
    for (unsigned m = 0; m < 12; ++m)
      for (unsigned k = 0; k < 16; ++k) {
        uint16_t *dst = element(tile, jobs[tile][2], m*16+k);
        float acc = value(*dst);
        for (unsigned n = 0; n < 16; ++n) {
          float x = value(*element(tile, jobs[tile][0], m*16+n));
          float w = value(*element(tile, jobs[tile][1], n*16+k));
          acc = value(bits(x*w + acc));
        }
        *dst = bits(acc);
      }
  }
  pending = 0;
}
void omrm_download_f16(uint32_t tile, uint32_t addr, void *dst, uint32_t elements)
{
  assert(tile < 3 && !(pending & (1u << tile)) && elements == 192);
  for (uint32_t i = 0; i < elements; ++i)
    ((uint16_t *)dst)[i] = *element(tile, addr, i);
#ifdef MOCK_CORRUPT_OUTPUT
  ((uint16_t *)dst)[elements - 1] = 0x7e00u;
#endif
}
