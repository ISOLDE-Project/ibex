/* Host-only stand-in for the RISC-V CSR/printing interface. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
static inline uint32_t isolde_get_tile_cnt(void) { return 3; }
static inline void isolde_clear_tile_ip(uint32_t mask) { (void)mask; }
#define START_PERFCNT(mask) do { (void)(mask); } while (0);
#define STOP_PERFCNT(mask) do { (void)(mask); } while (0);
static inline void printPerfCnt(void) {}
