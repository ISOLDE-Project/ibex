/* Host ABI and scheduling test double, NOT an RTL simulator.
 *
 * Generalised from radar_beamforming/tests/mock_runtime.c: the encoder uses
 * per-tile barriers (mask 1) as well as three-tile ones, so the wait mask is
 * checked against what is actually outstanding instead of a fixed 0x7.
 *
 * Every GEMM is deferred until the wait that covers it, so a missing barrier,
 * an operand overwritten while a launch is in flight, or a result read before
 * its launch completed all fail loudly rather than quietly producing the right
 * answer. What it does not model: RTL, DMA bank overlap, XIF, interrupts,
 * soft-float ABI or cycle timing.
 */
#include <assert.h>
#include <stdint.h>
#include <string.h>
#include <bsp/onnx_redmule_runtime.h>

enum { TILES = 3, SPM_WORDS = 4096 };

static uint16_t spm[TILES][SPM_WORDS];
static uint32_t pending, jobs[TILES][3];
unsigned mock_launches, mock_waits, mock_uploads, mock_downloads;
unsigned mock_max_cursor;

void mock_reset(void)
{
  memset(spm, 0, sizeof spm);
  pending = 0;
  mock_launches = mock_waits = mock_uploads = mock_downloads = 0;
  mock_max_cursor = 0;
}

static uint16_t *element(uint32_t tile, uint32_t addr, uint32_t i)
{
  uint32_t index = addr / 2 + (i / 16) * 32 + i % 16;
  assert(tile < TILES && addr % 64 == 0 && index < SPM_WORDS);
  if (index * 2 > mock_max_cursor) mock_max_cursor = index * 2;
  return &spm[tile][index];
}

static float value(uint16_t bits)
{
  _Float16 half;
  memcpy(&half, &bits, 2);
  return (float)half;
}

static uint16_t bits(float v)
{
  _Float16 half = (_Float16)v;
  uint16_t result;
  memcpy(&result, &half, 2);
  return result;
}

uint32_t omrm_addr_start(uint32_t tile, uint32_t bank)
{
  assert(tile < TILES && bank == 0);
  return 0;
}

uint32_t omrm_upload_f16(uint32_t tile, uint32_t addr, const void *src,
                         uint32_t elements, uint32_t negate)
{
  /* Touching a tile with work in flight is the bug this catches. */
  assert(tile < TILES && !(pending & (1u << tile)));
  assert(elements % 16 == 0 && negate <= 1);
  for (uint32_t i = 0; i < elements; ++i)
    *element(tile, addr, i) =
        (uint16_t)(((const uint16_t *)src)[i] ^ (negate ? 0x8000u : 0u));
  ++mock_uploads;
  return addr + (elements / 16) * 64;
}

void omrm_zero_f16(uint32_t tile, uint32_t addr, uint32_t elements)
{
  assert(tile < TILES && !(pending & (1u << tile)) && elements % 16 == 0);
  for (uint32_t i = 0; i < elements; ++i) *element(tile, addr, i) = 0;
}

void omrm_gemm_f16_16_12_16(uint32_t tile, uint32_t x, uint32_t w, uint32_t y)
{
  assert(tile < TILES && !(pending & (1u << tile)));
  /* The fixed per-tile slot layout both runtimes in this repo use. */
  assert(x == 0 && w == 768 && y == 1792);
  jobs[tile][0] = x;
  jobs[tile][1] = w;
  jobs[tile][2] = y;
  pending |= 1u << tile;
  ++mock_launches;
}

void omrm_wait(uint32_t mask)
{
  /* Waiting on a tile that was never launched, or leaving one outstanding,
   * is a scheduling bug even though the hardware might tolerate it. */
  assert(mask != 0 && mask == pending);
  for (unsigned tile = 0; tile < TILES; ++tile) {
    if (!(mask & (1u << tile))) continue;
    for (unsigned m = 0; m < 12; ++m)
      for (unsigned k = 0; k < 16; ++k) {
        uint16_t *dst = element(tile, jobs[tile][2], m * 16 + k);
        float acc = value(*dst);
        for (unsigned n = 0; n < 16; ++n) {
          float a = value(*element(tile, jobs[tile][0], m * 16 + n));
          float b = value(*element(tile, jobs[tile][1], n * 16 + k));
          acc = value(bits(a * b + acc));
        }
        *dst = bits(acc);
      }
  }
  pending = 0;
  ++mock_waits;
}

void omrm_download_f16(uint32_t tile, uint32_t addr, void *dst,
                       uint32_t elements)
{
  assert(tile < TILES && !(pending & (1u << tile)) && elements == 192);
  for (uint32_t i = 0; i < elements; ++i)
    ((uint16_t *)dst)[i] = *element(tile, addr, i);
  ++mock_downloads;
}
