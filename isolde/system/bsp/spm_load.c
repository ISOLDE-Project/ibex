/*
 *
 * Copyleft 2026 ISOLDE
 *
 */

#include <bsp/spm_load.h>

// #include "bsp/spm.h"
// #include "simple_system_common.h"
#include "tinyprintf.h"

/* Rows are 64 bytes apart in the narrow window; get_row() in spm.h is the
 * same shift, kept here so this file does not depend on the store loop. */
#define SPMLD_ROW_BYTES 64u

static void spmld_check(uint32_t spm_addr, uint32_t elems) {
  if (spm_addr & (SPMLD_ROW_BYTES - 1)) {
    printf("Error: spm_load/store address 0x%08x is not row aligned.\n",
           spm_addr);
    _Exit(0xbadc0de);
  }
  if (elems & 0x7) {
    printf("Error: spm_load/store elems=%d is not a multiple of 8.\n", elems);
    _Exit(0xbadc0de);
  }
}

static void spmld_start(uint32_t dmem_ptr, uint32_t spm_addr, uint32_t elems,
                        uint32_t dir) {
  spmld_check(spm_addr, elems);

  /* CSR_ISOLDE_TILE_INTR_EN resets to all-ones, and crt0.S enables both
   * mstatus.MIE and mie.MSIE while every vector points at
   * default_exc_handler. An unmasked completion would therefore trap into
   * the "EXCEPTION!!!" path rather than being handled. Polling is the
   * default, so mask the loader's event here; spm_dma_wait_irq() re-enables
   * it locally for the duration of the wfi. */
  isolde_set_intr_en(isolde_get_intr_en() & ~spmld_event_bit());

  /* clear a stale completion before arming a new transfer */
  SPMLD_STATUS = SPMLD_STATUS_DONE;

  SPMLD_SRC = dmem_ptr;
  SPMLD_DST_ROW = spm_addr / SPMLD_ROW_BYTES;
  SPMLD_LEN = elems;
  SPMLD_CTRL = SPMLD_CTRL_START | dir;
}

/* Both directions advance the SPM cursor the same way spm_write() does:
 * 8 payload words per row, so elems/8 rows. */
static inline uint32_t spmld_next_addr(uint32_t spm_addr, uint32_t elems) {
  return spm_addr + (elems / 8u) * SPMLD_ROW_BYTES;
}

void spm_load_async(uint32_t spm_addr, const uint32_t *src, uint32_t elems) {
  spmld_start((uint32_t)src, spm_addr, elems, 0u);
}

void spm_store_async(uint32_t *dst, uint32_t spm_addr, uint32_t elems) {
  spmld_start((uint32_t)dst, spm_addr, elems, SPMLD_CTRL_DIR_STORE);
}

void spm_dma_wait(void) {
  while ((SPMLD_STATUS & SPMLD_STATUS_DONE) == 0) {
    /* spin: a transfer is ~1.13 cycles per word, so this is short */
  }
  SPMLD_STATUS = SPMLD_STATUS_DONE; /* w1c */
}

void spm_dma_wait_irq(void) {
  uint32_t evt = spmld_event_bit();
  uint32_t saved_mask = isolde_get_intr_en();
  uint32_t saved_mstatus;

  /* Wake on the loader's event without taking a trap. wfi resumes on any
   * enabled pending interrupt regardless of mstatus.MIE, so clearing MIE
   * gives wake-without-trap - which is what this system needs, since there
   * is no machine-software-interrupt handler. MIE is mstatus bit 3, so the
   * 5-bit CSR immediate forms encode it directly. */
  asm volatile("csrrci %0, mstatus, 8" : "=r"(saved_mstatus)::"memory");

  /* add to the mask rather than replacing it: a tile GEMM may be in flight
   * and must keep its own enable bit. Spurious wakeups are harmless, the
   * loop re-tests. */
  isolde_set_intr_en(saved_mask | evt);

  while ((isolde_get_tile_ip() & evt) == 0) {
    asm volatile("wfi" ::: "memory");
  }

  /* Source before pending bit. done_o is a level, and tile_ip ORs the live
   * hardware event in AFTER the software clear (see ibex_cs_registers.sv),
   * so clearing ip while done_o is still high is undone in the same cycle. */
  SPMLD_STATUS = SPMLD_STATUS_DONE;
  isolde_clear_tile_ip(evt);

  isolde_set_intr_en(saved_mask);
  if (saved_mstatus & 0x8u) asm volatile("csrsi mstatus, 8" ::: "memory");
}

uint32_t spm_load(uint32_t spm_addr, const uint32_t *src, uint32_t elems) {
  spm_load_async(spm_addr, src, elems);
  spm_dma_wait();
  return spmld_next_addr(spm_addr, elems);
}

uint32_t spm_store(uint32_t *dst, uint32_t spm_addr, uint32_t elems) {
  spm_store_async(dst, spm_addr, elems);
  spm_dma_wait();
  return spmld_next_addr(spm_addr, elems);
}
