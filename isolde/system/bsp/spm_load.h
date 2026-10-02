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

#include <bsp/spm.h>

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
#define SPMLD_CTRL_NEGATE_FP16 (1u << 2)
#define SPMLD_CTRL_ZERO_FILL (1u << 3)

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
 *
 *     Bank 8 is populated only between adjacent payload rows.  The final
 *     row's bank 8 is not accessed, so src/dst require exactly elems words
 *     and no guard word.
 *
 * Blocks until the transfer completes. Returns the next free SPM address, so
 * it is a drop-in for spm_write().
 */
uint32_t spm_load(uint32_t spm_addr, const uint32_t *src, uint32_t elems);
uint32_t spm_fill_zero(uint32_t spm_addr, uint32_t elems);
uint32_t spm_load_negate_f16(uint32_t spm_addr, const uint32_t *src, uint32_t elems);

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
void spm_fill_zero_async(uint32_t spm_addr, uint32_t elems);
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


uint32_t get_addr_start(uint32_t row);
uint32_t get_addr_end(uint32_t row);
static inline uint32_t get_row(uint32_t addr) {
  return addr >> BANK_OFFSET_SHIFT;
}

#endif /* __SPM_LOAD_H__ */
