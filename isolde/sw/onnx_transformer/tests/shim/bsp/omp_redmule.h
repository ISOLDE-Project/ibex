/* Host-only stand-in for the bare-metal BSP interface used by main.c. */
#ifndef HOST_OMP_REDMULE_H
#define HOST_OMP_REDMULE_H
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
static inline unsigned isolde_get_tile_cnt(void) { return 3; }
static inline void isolde_clear_tile_ip(unsigned mask) { (void)mask; }
#define START_PERFCNT(id) do { (void)(id); } while (0);
#define STOP_PERFCNT(id) do { (void)(id); } while (0);
static inline void printPerfCnt(void) {}
#endif
