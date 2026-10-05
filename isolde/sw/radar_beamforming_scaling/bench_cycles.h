/* SPDX-License-Identifier: Apache-2.0 */
#ifndef BF_BENCH_CYCLES_H
#define BF_BENCH_CYCLES_H
#include <stdint.h>

#ifdef BF_BENCH_HOST_TEST
#define BF_BENCH_SOURCE "host_mock"
void bf_mock_bench_start(void);
uint32_t bf_mock_bench_stop(void);
static inline void bf_bench_start(void) { bf_mock_bench_start(); }
static inline uint32_t bf_bench_stop(void) { return bf_mock_bench_stop(); }
#else
#if !defined(__riscv) || __riscv_xlen != 32
#error "FPGA firmware needs RV32; BF_BENCH_HOST_TEST is only for host tests"
#endif
#include <bsp/simple_system_common.h>
#include <bsp/simple_system_regs.h>
#define BF_BENCH_SOURCE "hardware_counter"
#define BF_BENCH_PERFCNT_ID 0xBFu

/* Match BSP printPerfCnt() and coremark/core_portme.c:
 * first write of the ID to MMADDR_PERF_COUNTERS starts aida_perfcnt,
 * second write stops it; the 32-bit elapsed cycles are at base + 4.
 * These MMIO macros do NOT enable/reset the Ibex mcycle CSR. The cluster
 * event wait uses WFI, so use the platform counter for elapsed timing.
 */
static inline void bf_bench_fence(void)
{
  __asm__ volatile ("fence iorw, iorw" ::: "memory");
}
static inline void bf_bench_start(void)
{
  bf_bench_fence();
  START_PERFCNT(BF_BENCH_PERFCNT_ID)
  bf_bench_fence();
}
static inline uint32_t bf_bench_stop(void)
{
  bf_bench_fence();
  STOP_PERFCNT(BF_BENCH_PERFCNT_ID)
  bf_bench_fence();
  return *(volatile uint32_t *)(MMADDR_PERF_COUNTERS + 4u);
}
#endif
#endif
