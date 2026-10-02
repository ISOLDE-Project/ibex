/*
 *
 * Copyleft 2026 ISOLDE
 *
 * Test-local CPU reference implementation for spm_dma_test.
 *
 * This intentionally preserves the legacy bsp/spm.c spm_write()/spm_read()
 * semantics so the hardware loader can be checked against an independent
 * CPU implementation without restoring those functions to the production BSP.
 *
 * Legacy layout:
 *   - one narrow SPM row is 9 x uint32_t banks, 64 bytes apart
 *   - 8 words per row are payload
 *   - bank 8 of row r duplicates bank 0 of row r+1
 *   - consequently the legacy CPU write reads src[elems]
 *   - and the legacy CPU read writes dst[elems]
 *
 * The current hardware loader intentionally differs only at the final row:
 * it stops after bank 7, so its exact-length transfer does not touch the
 * guard word or the final bank 8.
 *
 * Keep every symbol static: this file is a verification oracle, not a BSP API.
 */

#ifndef ISOLDE_SPM_CPU_REF_H
#define ISOLDE_SPM_CPU_REF_H

// #include <stdint.h>

// #include <bsp/spm.h>
// #include <bsp/simple_system_common.h>

#define SPM_CPU_REF_PAYLOAD_WORDS (NUM_BANKS - 1u)

/*
 * Preserve the old spm_write() algorithm:
 * each row writes all 9 physical banks, then advances the source by only
 * 8 payload words. The ninth word is therefore re-used as bank 0 of the
 * following row.
 */
static __attribute__((noinline))
uint32_t spm_cpu_ref_write(uint32_t spm_addr, uint32_t *src, uint32_t elems)
{
  uint32_t src_offset = 0u;
  uint32_t row = spm_addr >> BANK_OFFSET_SHIFT;
  uint32_t last_row = row + elems / SPM_CPU_REF_PAYLOAD_WORDS;

  while (row < last_row) {
    volatile uint32_t *spm_row =
        (volatile uint32_t *)(SPM_NARROW_ADDR +
                              (row << BANK_OFFSET_SHIFT));

    for (uint32_t bank = 0u; bank < NUM_BANKS; ++bank)
      spm_row[bank] = src[src_offset + bank];

    ++row;
    src_offset += SPM_CPU_REF_PAYLOAD_WORDS;
  }

  return row << BANK_OFFSET_SHIFT;
}

/*
 * Preserve the old spm_read() algorithm:
 * each row reads all 9 banks and advances the destination by 8 words.
 * Intermediate bank-8 values are overwritten by the equal next-row bank-0
 * value; the final bank 8 lands in dst[elems].
 */
static __attribute__((noinline))
uint32_t spm_cpu_ref_read(uint32_t *dst, uint32_t spm_addr, uint32_t elems)
{
  uint32_t dst_offset = 0u;
  uint32_t row = spm_addr >> BANK_OFFSET_SHIFT;
  uint32_t last_row = row + elems / SPM_CPU_REF_PAYLOAD_WORDS;

  while (row < last_row) {
    volatile const uint32_t *spm_row =
        (volatile const uint32_t *)(SPM_NARROW_ADDR +
                                    (row << BANK_OFFSET_SHIFT));

    for (uint32_t bank = 0u; bank < NUM_BANKS; ++bank)
      dst[dst_offset + bank] = spm_row[bank];

    ++row;
    dst_offset += SPM_CPU_REF_PAYLOAD_WORDS;
  }

  return row << BANK_OFFSET_SHIFT;
}

#endif /* ISOLDE_SPM_CPU_REF_H */
