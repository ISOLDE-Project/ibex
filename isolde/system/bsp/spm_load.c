/*
 *
 * Copyleft 2026 ISOLDE
 *
 */

#include <bsp/spm_load.h>

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

  /* Single channel: never touch the descriptor while a transfer is running.
   * The RTL freezes those registers when busy, but waiting here keeps the
   * caller honest and avoids losing the transfer silently. */
  while (spm_dma_busy()) {
  }

  /* Clear a stale completion before arming. Source (STATUS) first, then the
   * latched pending bit: tile_ip is sticky and the hardware ORs the live
   * event in AFTER the software clear, so the reverse order does nothing.
   * Without this, a later spm_dma_wait_irq() sees a pending bit left over
   * from an earlier polled transfer and returns immediately. */
  SPMLD_STATUS = SPMLD_STATUS_DONE;
  isolde_evt_clear(spmld_event_bit());

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

  isolde_evt_wait(evt);

  /* done_o is a level, and the barrier merges set after clear, so the source
   * has to be quiesced before the pending bit will stay cleared. */
  SPMLD_STATUS = SPMLD_STATUS_DONE;
  isolde_evt_clear(evt);
}

uint32_t spm_load(uint32_t spm_addr, const uint32_t *src, uint32_t elems) {
  spm_load_async(spm_addr, src, elems);
  spm_dma_wait();
  return spmld_next_addr(spm_addr, elems);
}

uint32_t spm_load_negate_f16(uint32_t spm_addr,
                             const uint32_t *src,
                             uint32_t elems){
  spmld_start((uint32_t)src, spm_addr, elems, SPMLD_CTRL_NEGATE_FP16);
  spm_dma_wait();
  return spmld_next_addr(spm_addr, elems);
}

uint32_t spm_store(uint32_t *dst, uint32_t spm_addr, uint32_t elems) {
  spm_store_async(dst, spm_addr, elems);
  spm_dma_wait();
  return spmld_next_addr(spm_addr, elems);
}

///
uint32_t get_addr_start(uint32_t row) {
  uint32_t bank_index = 0;
  uint32_t res = 0;
  res |= (row << BANK_OFFSET_SHIFT);  // bits [31:6]
  res |= (bank_index << BANK_SHIFT);  // bits [5:2]
  return res;
}

uint32_t get_addr_end(uint32_t row) {
  uint32_t bank_index = (NUM_BANKS - 1);
  uint32_t res = 0;
  res |= (row << BANK_OFFSET_SHIFT);  // bits [31:6]
  res |= (bank_index << BANK_SHIFT);  // bits [5:2]
  return res;
}