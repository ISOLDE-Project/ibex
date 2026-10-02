/*
 *
 * Copyleft 2026 ISOLDE
 *
 * Barrier primitive over the cluster event vector.
 *
 * The pending bits are latched by isolde_event_barrier in the cluster, on the
 * ungated clock, and read back through CSR_ISOLDE_TILE_IP. Bit i is tile i;
 * the top bit (index N_HWE_TILES) belongs to isolde_spm_loader.
 *
 * Two rules, both consequences of the barrier's set-wins-over-clear merge:
 *
 *  1. For a LEVEL source - isolde_spm_loader's done_o - drop the source
 *     before clearing the pending bit, or the barrier re-arms it in the same
 *     cycle. Tile events are pulses and have no such requirement.
 *
 *  2. isolde_evt_wait() deliberately does NOT clear. The caller knows how to
 *     quiesce its own source; clearing here would be wrong for level sources
 *     and would also discard bits the caller did not ask about.
 *
 * On interrupts: crt0.S enables mstatus.MIE and mie.MSIE, but every vector
 * goes to default_exc_handler, so there is no machine-software-interrupt
 * handler. These helpers clear MIE around the wfi: the core still wakes,
 * because ibex_top gates the clock on irq_pending = |(mip & mie), which does
 * not consult mstatus.MIE. If crt0 is changed to leave MIE clear, this
 * becomes a no-op and everything still works.
 */

#ifndef __ISOLDE_EVT_H__
#define __ISOLDE_EVT_H__

#include <stdint.h>

#include "simple_system_common.h"

/** Event bit for tile t. */
static inline uint32_t isolde_evt_tile(unsigned t) { return 1u << t; }

/** Event bit for the SPM loader: the spare bit above the per-tile bits.
 *  Read from CSR_ISOLDE_TILE_CNT so it tracks N_HWE_TILES automatically. */
static inline uint32_t isolde_evt_loader(void) {
  return 1u << isolde_get_tile_cnt();
}

/** Which of `mask` are pending right now. Non-blocking. */
static inline uint32_t isolde_evt_poll(uint32_t mask) {
  return isolde_get_tile_ip() & mask;
}

/** Clear pending bits. For level sources, quiesce the source first. */
static inline void isolde_evt_clear(uint32_t mask) {
  isolde_clear_tile_ip(mask);
}

/**
 * Sleep until at least one bit of `mask` is pending; returns the bits that
 * fired. Does not clear them.
 *
 * Safe against the wakeup race that motivated the barrier: because pending
 * bits are sticky, an event that lands before the wfi keeps irq_pending
 * asserted, so the wfi returns immediately instead of sleeping forever.
 */
static inline uint32_t isolde_evt_wait(uint32_t mask) {
  uint32_t saved_en = isolde_get_intr_en();
  uint32_t saved_mstatus;
  uint32_t hit;

  /* wake without trapping - MIE is mstatus bit 3, so the 5-bit CSR
   * immediate forms encode it directly and need no scratch register */
  asm volatile("csrrci %0, mstatus, 8" : "=r"(saved_mstatus)::"memory");

  /* add to the enable mask, never replace it: another completion may be
   * outstanding and must keep its own bit */
  isolde_set_intr_en(saved_en | mask);

  while (((hit = isolde_get_tile_ip()) & mask) == 0u) {
    asm volatile("wfi" ::: "memory");
  }

  isolde_set_intr_en(saved_en);
  if (saved_mstatus & 0x8u) asm volatile("csrsi mstatus, 8" ::: "memory");

  return hit & mask;
}

/**
 * Sleep until ALL bits of `mask` are pending. This is the fork/join form:
 * launch k tiles, then wait for the whole set. Does not clear.
 */
static inline void isolde_evt_wait_all(uint32_t mask) {
  uint32_t saved_en = isolde_get_intr_en();
  uint32_t saved_mstatus;

  asm volatile("csrrci %0, mstatus, 8" : "=r"(saved_mstatus)::"memory");
  isolde_set_intr_en(saved_en | mask);

  while ((isolde_get_tile_ip() & mask) != mask) {
    asm volatile("wfi" ::: "memory");
  }

  isolde_set_intr_en(saved_en);
  if (saved_mstatus & 0x8u) asm volatile("csrsi mstatus, 8" ::: "memory");
}

/** Spin rather than sleep. Cheaper for short waits, identical semantics. */
static inline uint32_t isolde_evt_spin(uint32_t mask) {
  uint32_t hit;
  while (((hit = isolde_get_tile_ip()) & mask) == 0u) {
  }
  return hit & mask;
}

#endif /* __ISOLDE_EVT_H__ */