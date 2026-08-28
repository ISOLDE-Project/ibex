/*
 *
 * Copyleft 2026 ISOLDE
 *
 * Hardware-accelerated replacement for spm_write() / spm_read().
 *
 * The isolde_spm_loader walks the 9-bank SPM row layout in hardware, so the
 * CPU only writes a five-word descriptor instead of executing a store loop.
 * Measured 1.13 cycles per payload word against ~3.4 for spm_write(), i.e.
 * about 3x the fill bandwidth.
 *
 * IMPORTANT - the loader shares the narrow SPM port with the CPU and is
 * steered by the same TILESEL CSR as an ordinary store. Do not change TILESEL
 * while a transfer is in flight: isolde_tile_router selects the destination
 * combinationally from the current value.
 */

#ifndef __SPM_LOAD_H__
#define __SPM_LOAD_H__

// #include <stdint.h>

// #include "simple_system_common.h"
// #include "simple_system_regs.h"

#include <bsp/isolde_evt.h>

/* Register block. Must match REG_ADDR on isolde_spm_loader and the SPMLD_IDX
 * rule in isolde_cluster.sv addr_map. */
#define SPMLD_ADDR 0x80000100

#define SPMLD_SRC (*(volatile uint32_t *)(SPMLD_ADDR + 0x00))
#define SPMLD_DST_ROW (*(volatile uint32_t *)(SPMLD_ADDR + 0x04))
#define SPMLD_LEN (*(volatile uint32_t *)(SPMLD_ADDR + 0x08))
#define SPMLD_CTRL (*(volatile uint32_t *)(SPMLD_ADDR + 0x0C))
#define SPMLD_STATUS (*(volatile uint32_t *)(SPMLD_ADDR + 0x10))

#define SPMLD_CTRL_START (1u << 0)
#define SPMLD_CTRL_DIR_STORE (1u << 1) /* 0 = DMEM->SPM, 1 = SPM->DMEM */

#define SPMLD_STATUS_BUSY (1u << 0)
#define SPMLD_STATUS_DONE (1u << 1)

/* The loader owns the spare event bit above the per-tile bits. */
static inline uint32_t spmld_event_bit(void) { return isolde_evt_loader(); }

/**
 * Copies elems words from data memory into the SPM of the currently selected
 * tile, producing a byte-identical image to spm_write().
 *
 *   - spm_addr must be a row start, i.e. a multiple of 64
 *   - src must point into data memory (.rodata and .data both qualify; the
 *     linker already places them in dataram). Stack buffers will NOT work:
 *     the stack is a separate memory port the loader cannot reach.
 *   - elems must be a multiple of 8
 *   - src[elems] is read to fill the last bank-8 slot, exactly as spm_write()
 *     does, so the source buffer must be padded by one word
 *
 * Blocks until the transfer completes. Returns the next free SPM address, so
 * it is a drop-in for spm_write().
 */
uint32_t spm_load(uint32_t spm_addr, const uint32_t *src, uint32_t elems);

/**
 * The reverse: SPM of the selected tile back into data memory. Drop-in for
 * spm_read(), same constraints, same return convention.
 */
uint32_t spm_store(uint32_t *dst, uint32_t spm_addr, uint32_t elems);

/**
 * Non-blocking variants. Start one, do something useful, then wait.
 * Only one transfer may be in flight - the loader has a single channel.
 */
void spm_load_async(uint32_t spm_addr, const uint32_t *src, uint32_t elems);
void spm_store_async(uint32_t *dst, uint32_t spm_addr, uint32_t elems);

/** Spin until the current transfer retires. */
void spm_dma_wait(void);

/** Sleep until the current transfer retires. Cheaper than spinning when the
 *  transfer is long, but only usable if no other event shares the mask. */
void spm_dma_wait_irq(void);

/** True while a transfer is in flight. */
static inline int spm_dma_busy(void) {
  return (SPMLD_STATUS & SPMLD_STATUS_BUSY) != 0;
}

#endif /* __SPM_LOAD_H__ */
