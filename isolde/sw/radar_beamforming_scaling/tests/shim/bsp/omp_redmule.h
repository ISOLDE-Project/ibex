/* Host stand-in only; never place this directory in FPGA include paths. */
#ifndef BF_TEST_OMP_H
#define BF_TEST_OMP_H
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#ifndef MOCK_TILE_COUNT
#define MOCK_TILE_COUNT 3
#endif
static inline uint32_t isolde_get_tile_cnt(void) { return MOCK_TILE_COUNT; }
static inline void isolde_clear_tile_ip(uint32_t mask) { assert(mask > 0 && mask <= 7); }
#define START_PERFCNT(mask) do { assert((mask) == 1); } while (0);
#define STOP_PERFCNT(mask) do { assert((mask) == 1); } while (0);
#endif
