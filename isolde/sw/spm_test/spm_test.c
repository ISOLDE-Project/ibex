/*
 *
 * Copyleft 2026 ISOLDE
 *
 * SPM transfer regression for the CPU store loop.
 *
 * This test deliberately exercises ONLY spm_write / spm_read. Once the
 * isolde_spm_loader is integrated it must keep passing unchanged: the RTL
 * patch inserts an isolde_mux_tcdm into the CPU's route to both the narrow
 * SPM port and data memory, and this is the regression that proves that
 * arbiter did not break the path which already worked.
 *
 * It also holds the baseline transfer cost the loader is measured against.
 * Do not repoint it at the loader - see spm_dma_test.
 */

#include <bsp/simple_system_common.h>
#include <bsp/simple_system_regs.h>
#include <bsp/spm.h>
#include <bsp/tinyprintf.h>
#include <stdlib.h>

#include "golden.h"

enum { GOLDEN_ELEMS = sizeof(golden) / sizeof(golden[0]) };

#define SPM_CHECK_MAX_ELEMS GOLDEN_ELEMS
#include "spm_checks.h"

static uint32_t cpu_put(uint32_t addr, uint32_t *src, uint32_t elems) {
  return spm_write(addr, src, elems);
}

static uint32_t cpu_get(uint32_t *dst, uint32_t addr, uint32_t elems) {
  return spm_read(dst, addr, elems);
}

static const spm_backend_t cpu = {"cpu", cpu_put, cpu_get};

static inline uint32_t read_mcycle(void) {
  uint32_t c;
  asm volatile("csrr %0, mcycle" : "=r"(c));
  return c;
}

/* Two sizes, so the fixed per-call cost separates from the per-word cost:
 * cycles(n) = F + c*n  =>  c = (cy2 - cy1) / (n2 - n1). */
static void measure(uint32_t elems) {
  uint32_t addr = get_addr_start(0);
  uint32_t t0, t1, put_cy, get_cy;

  spmc_fill(elems, 0);

  START_PERFCNT(0x1)
  t0 = read_mcycle();
  cpu.put(addr, spmc_src, elems);
  t1 = read_mcycle();
  STOP_PERFCNT(0x1)
  put_cy = t1 - t0;

  START_PERFCNT(0x2)
  t0 = read_mcycle();
  cpu.get(spmc_dst, addr, elems);
  t1 = read_mcycle();
  STOP_PERFCNT(0x2)
  get_cy = t1 - t0;

  printf("***  %4d words : put %6d cy (%d.%02d/word)   get %6d cy (%d.%02d/word)\n",
         elems, put_cy, put_cy / elems, (100u * put_cy / elems) % 100u, get_cy,
         get_cy / elems, (100u * get_cy / elems) % 100u);
}

int main(int argc, char *argv[]) {
  int testOK = 1;
  uint32_t half = (GOLDEN_ELEMS / 2u) & ~7u;

  (void)argc;
  (void)argv;

  printf("***\n");
  printf("***  BANK_DATA_WIDTH     = 0x%08x\n", BANK_DATA_WIDTH);
  printf("***  NUM_BANKS           = 0x%08x\n", NUM_BANKS);
  printf("***  WIDE_ADDR_ALIGNMENT = 0x%08x\n", WIDE_ADDR_ALIGNMENT);
  printf("***  backend             = CPU store loop\n");
  printf("***  payload words       = %d\n", GOLDEN_ELEMS);
  printf("***\n");

  testOK = spmc_run_all(&cpu, GOLDEN_ELEMS) && testOK;

  printf("\n*** transfer cost, CPU store loop\n");
  measure(half);
  measure(GOLDEN_ELEMS);
  printf("***  subtract the two to separate fixed cost from cost per word\n");

  printf("\n*** spm_test: %s ***\n", testOK ? "PASS" : "FAIL");

#ifdef RV_DM_TEST
  while (1) {
    asm volatile("wfi");
  }
#else
  return testOK ? 0x0 : 0xBADC0FFE;
#endif
}
