/*
 *
 * Copyleft 2026 ISOLDE
 *
 * Shared SPM transfer checks, parameterised by backend so the same logic runs
 * against the CPU store loop (spm_write / spm_read) and against the hardware
 * loader (spm_load / spm_store).
 *
 * Layout contract being asserted, from bsp/spm.c:
 *   - a row is 9 words at narrow offsets (row << 6) + (bank << 2)
 *   - only 8 of them are payload; bank 8 of row r duplicates bank 0 of row r+1
 *   - therefore a put reads src[elems] and a get writes dst[elems], one word
 *     PAST the nominal length, and every buffer must be padded by one word
 *   - elems must be a multiple of 8
 */

#ifndef ISOLDE_SPM_CHECKS_H
#define ISOLDE_SPM_CHECKS_H

#include <stdint.h>

#ifndef SPM_CHECK_MAX_ELEMS
#define SPM_CHECK_MAX_ELEMS 128
#endif

#define SPM_ROW_WORDS 16u /* rows are 64 B apart in the narrow window */
#define SPM_ROW_BYTES 64u
#define SPM_BANKS 9u
#define SPM_PAYLOAD 8u

typedef uint32_t (*spm_put_fn)(uint32_t addr, uint32_t *src, uint32_t elems);
typedef uint32_t (*spm_get_fn)(uint32_t *dst, uint32_t addr, uint32_t elems);

typedef struct {
  const char *name;
  spm_put_fn put;
  spm_get_fn get;
} spm_backend_t;

/* padded working buffers, +1 for the shared bank-8 word */
static uint32_t spmc_src[SPM_CHECK_MAX_ELEMS + 1];
static uint32_t spmc_dst[SPM_CHECK_MAX_ELEMS + 1];
static uint32_t spmc_dst2[SPM_CHECK_MAX_ELEMS + 1];

static inline volatile uint32_t *spmc_window(void) {
  return (volatile uint32_t *)SPM_NARROW_ADDR;
}

static inline uint32_t spmc_raw(uint32_t row, uint32_t bank) {
  return spmc_window()[row * SPM_ROW_WORDS + bank];
}

static inline void spmc_raw_set(uint32_t row, uint32_t bank, uint32_t v) {
  spmc_window()[row * SPM_ROW_WORDS + bank] = v;
}

static void spmc_fill(uint32_t elems, uint32_t seed) {
  for (uint32_t i = 0; i < elems; ++i)
    spmc_src[i] = (i * 0x9E3779B9u) ^ (seed + i);
  spmc_src[elems] = 0xC0FFEE00u ^ seed; /* the shared word - it IS compared */
}

static int spmc_report(const char *backend, const char *what, int ok) {
  printf("  %-8s %-38s : %s\n", backend, what, ok ? "PASS" : "FAIL");
  return ok;
}

static int spmc_cmp(const uint32_t *ref, const uint32_t *got, uint32_t elems) {
  int ok = 1;
  uint32_t shown = 0;
  for (uint32_t i = 0; i < elems; ++i)
    if (ref[i] != got[i]) {
      ok = 0;
      if (shown++ < 4)
        printf("    index %d: expected 0x%08x got 0x%08x\n", i, ref[i], got[i]);
    }
  return ok;
}

/* ------------------------------------------------------------------ */
/* round trip at an arbitrary base row                                 */
/* ------------------------------------------------------------------ */
static int spmc_roundtrip(const spm_backend_t *b, uint32_t row, uint32_t elems,
                          uint32_t seed) {
  /* row is encoded in the address; reported by the caller */
  uint32_t addr = get_addr_start(row);

  spmc_fill(elems, seed);
  b->put(addr, spmc_src, elems);
  b->get(spmc_dst, addr, elems);

  (void)row;
  return spmc_report(b->name, "round trip", spmc_cmp(spmc_src, spmc_dst, elems));
}

/* ------------------------------------------------------------------ */
/* chained blocks, the pattern redmule_upload() uses for X, W and Y     */
/* ------------------------------------------------------------------ */
static int spmc_chained(const spm_backend_t *b, uint32_t row, uint32_t elems) {
  uint32_t half = (elems / 2u) & ~7u;
  uint32_t addr_a = get_addr_start(row);
  uint32_t addr_b, expect;
  int ok = 1;

  spmc_fill(elems, 0x5A5Au);
  addr_b = b->put(addr_a, spmc_src, half);

  expect = addr_a + (half / SPM_PAYLOAD) * SPM_ROW_BYTES;
  if (addr_b != expect) {
    printf("    cursor: expected 0x%08x got 0x%08x\n", expect, addr_b);
    ok = 0;
  }

  b->put(addr_b, spmc_src + half, half);
  b->get(spmc_dst, addr_a, half);
  b->get(spmc_dst2, addr_b, half);

  ok = spmc_cmp(spmc_src, spmc_dst, half) && ok;
  ok = spmc_cmp(spmc_src + half, spmc_dst2, half) && ok;

  return spmc_report(b->name, "chained blocks + returned cursor", ok);
}

/* ------------------------------------------------------------------ */
/* bank-8 duplication, INCLUDING the final row                         */
/*                                                                     */
/* The final row's bank 8 comes from src[elems] and is compared by no   */
/* payload check anywhere. RedMulE still reads it, so it is checked     */
/* explicitly here - a transfer engine that zeroes it is otherwise      */
/* invisible to every round trip.                                      */
/* ------------------------------------------------------------------ */
static int spmc_bank8(const spm_backend_t *b, uint32_t row, uint32_t elems) {
  uint32_t rows = elems / SPM_PAYLOAD;
  int ok = 1;

  spmc_fill(elems, 0x1234u);
  b->put(get_addr_start(row), spmc_src, elems);

  for (uint32_t r = 0; r + 1 < rows; ++r) {
    uint32_t last = spmc_raw(row + r, 8);
    uint32_t first = spmc_raw(row + r + 1, 0);
    if (last != first) {
      ok = 0;
      printf("    row %d bank8=0x%08x != row %d bank0=0x%08x\n", r, last, r + 1,
             first);
    }
  }

  {
    uint32_t tail = spmc_raw(row + rows - 1, 8);
    if (tail != spmc_src[elems]) {
      ok = 0;
      printf("    final row bank8=0x%08x, expected src[%d]=0x%08x\n", tail,
             elems, spmc_src[elems]);
    }
  }

  return spmc_report(b->name, "bank-8 duplication incl. last row", ok);
}

/* ------------------------------------------------------------------ */
/* overrun: nothing outside [row, row+rows) may be touched             */
/* ------------------------------------------------------------------ */
static int spmc_overrun(const spm_backend_t *b, uint32_t row, uint32_t elems) {
  const uint32_t GUARD = 0xDEADBEEFu;
  uint32_t rows = elems / SPM_PAYLOAD;
  int ok = 1;

  for (uint32_t k = 0; k < SPM_BANKS; ++k) {
    if (row > 0) spmc_raw_set(row - 1, k, GUARD);
    spmc_raw_set(row + rows, k, GUARD);
  }

  spmc_fill(elems, 0x77u);
  b->put(get_addr_start(row), spmc_src, elems);

  for (uint32_t k = 0; k < SPM_BANKS; ++k) {
    if (row > 0 && spmc_raw(row - 1, k) != GUARD) {
      ok = 0;
      printf("    underrun into row %d bank %d\n", row - 1, k);
    }
    if (spmc_raw(row + rows, k) != GUARD) {
      ok = 0;
      printf("    overrun into row %d bank %d\n", row + rows, k);
    }
  }

  return spmc_report(b->name, "no over/underrun", ok);
}

/* ------------------------------------------------------------------ */
/* the whole basic suite for one backend                               */
/* ------------------------------------------------------------------ */
static int spmc_run_all(const spm_backend_t *b, uint32_t elems) {
  int ok = 1;
  ok = spmc_roundtrip(b, 0, elems, 0x0000u) && ok;   /* base row 0 */
  ok = spmc_roundtrip(b, 2, elems, 0x0F0Fu) && ok;   /* non-zero base row */
  ok = spmc_chained(b, 0, elems) && ok;
  ok = spmc_bank8(b, 0, elems) && ok;
  ok = spmc_overrun(b, 4, elems) && ok;
  return ok;
}

#endif /* ISOLDE_SPM_CHECKS_H */
