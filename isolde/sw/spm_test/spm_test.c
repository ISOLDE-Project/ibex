/*
 *
 * Copyleft 2026 ISOLDE
 *
 * SPM transfer regression.
 *
 * Exercises the row-based API (spm_write / spm_read) rather than the
 * element-wise to_spm / from_spm, because the row path is what the GEMM
 * upload/download helpers in omp_redmule.h actually use, and what the
 * isolde_spm_loader is intended to replace.
 *
 * Build the same test against the hardware loader with -DUSE_SPM_LOADER once
 * the loader is integrated; the checks below then become its reference.
 *
 * Two properties of the row layout that the test relies on, both inherited
 * from bsp/spm.c and neither obvious:
 *
 *   1. A row holds 9 words but only 8 of them are payload. Bank 8 of row r is
 *      a copy of bank 0 of row r+1. Consequently spm_write() reads src[elems]
 *      and spm_read() writes dst[elems] - one word PAST the nominal length.
 *      Every buffer here is therefore padded by one word.
 *
 *   2. elems must be a multiple of 8, since spm_write() computes its row count
 *      as elems / (NUM_BANKS - 1) and silently drops any remainder.
 */

#include <bsp/simple_system_common.h>
#include <bsp/simple_system_regs.h>
#include <bsp/spm.h>
#include <bsp/tinyprintf.h>
#include <stdlib.h>

#include "cmp_utils.h"
#include "golden.h"

#ifdef USE_SPM_LOADER
#include <bsp/spm_load.h>
#define SPM_PUT(addr, src, n) spm_load((addr), (src), (n))
#define SPM_GET(dst, addr, n) spm_store((dst), (addr), (n))
#define SPM_BACKEND "hardware loader"
#else
#define SPM_PUT(addr, src, n) spm_write((addr), (src), (n))
#define SPM_GET(dst, addr, n) spm_read((dst), (addr), (n))
#define SPM_BACKEND "CPU store loop"
#endif

/* Nominal payload length, and the padded length the row API needs.
 * An enum constant, not a `static const int` - the latter is not an integer
 * constant expression in C and cannot size a file-scope array. */
enum {
  GOLDEN_ELEMS = sizeof(golden) / sizeof(golden[0]),
  BUF_ELEMS = GOLDEN_ELEMS + 1, /* + the shared bank-8 word */
  ROW_WORDS = 16                /* rows are 64 B apart in the narrow window */
};

/* Padded working copies. golden itself is exactly GOLDEN_ELEMS long, so
 * handing it straight to spm_write() would read one word off the end. */
static uint32_t src_buf[BUF_ELEMS];
static uint32_t dst_buf[BUF_ELEMS];
static uint32_t dst_buf2[BUF_ELEMS];

static inline uint32_t read_mcycle(void) {
  uint32_t c;
  asm volatile("csrr %0, mcycle" : "=r"(c));
  return c;
}

static void fill_src(uint32_t seed) {
  for (uint32_t i = 0; i < GOLDEN_ELEMS; ++i) src_buf[i] = golden[i] ^ seed;
  src_buf[GOLDEN_ELEMS] = 0xA5A5A5A5u; /* padding, never compared */
}

static int check(const char *what, const uint32_t *ref, const uint32_t *got,
                 uint32_t elems) {
  int ok = (int)cmp_arrays((uint32_t *)ref, (uint32_t *)got, elems);
  printf("  %-34s : %s\n", what, ok ? "PASS" : "FAIL");
  return ok;
}

/* ------------------------------------------------------------------ */
/* 1. round trip at row 0                                             */
/* ------------------------------------------------------------------ */
static int test_roundtrip_row0(void) {
  uint32_t addr = get_addr_start(0);

  fill_src(0);
  SPM_PUT(addr, src_buf, GOLDEN_ELEMS);
  SPM_GET(dst_buf, addr, GOLDEN_ELEMS);

  return check("round trip, row 0", src_buf, dst_buf, GOLDEN_ELEMS);
}

/* ------------------------------------------------------------------ */
/* 2. round trip at a non-zero row - catches base-row arithmetic      */
/* ------------------------------------------------------------------ */
static int test_roundtrip_row2(void) {
  uint32_t addr = get_addr_start(2);

  fill_src(0x0F0F0F0Fu);
  SPM_PUT(addr, src_buf, GOLDEN_ELEMS);
  SPM_GET(dst_buf, addr, GOLDEN_ELEMS);

  return check("round trip, row 2", src_buf, dst_buf, GOLDEN_ELEMS);
}

/* ------------------------------------------------------------------ */
/* 3. chained blocks - the pattern redmule_upload() uses for X, W, Y   */
/*    Two blocks written back to back must not disturb each other.     */
/* ------------------------------------------------------------------ */
static int test_chained_blocks(void) {
  const uint32_t half = (GOLDEN_ELEMS / 2) & ~7u; /* keep the multiple of 8 */
  uint32_t addr_a = get_addr_start(0);
  uint32_t addr_b;
  uint32_t next;
  int ok = 1;

  fill_src(0);
  addr_b = SPM_PUT(addr_a, src_buf, half);

  /* the returned cursor must be exactly half/8 rows further on */
  next = addr_a + (half / 8u) * (ROW_WORDS * 4u);
  if (addr_b != next) {
    printf("  chained cursor: expected 0x%08x got 0x%08x\n", next, addr_b);
    ok = 0;
  }

  SPM_PUT(addr_b, src_buf + half, half);

  SPM_GET(dst_buf, addr_a, half);
  SPM_GET(dst_buf2, addr_b, half);

  ok = check("chained block A", src_buf, dst_buf, half) && ok;
  ok = check("chained block B", src_buf + half, dst_buf2, half) && ok;
  return ok;
}

/* ------------------------------------------------------------------ */
/* 4. the bank-8 duplication invariant                                 */
/*    Row r bank 8 must equal row r+1 bank 0. This is the contract any */
/*    replacement transfer engine has to reproduce byte for byte.      */
/* ------------------------------------------------------------------ */
static int test_bank8_duplication(void) {
  volatile uint32_t *spm = (volatile uint32_t *)SPM_NARROW_ADDR;
  const uint32_t rows = GOLDEN_ELEMS / 8u;
  uint32_t base_row = 0;
  int ok = 1;

  fill_src(0x12345678u);
  SPM_PUT(get_addr_start(base_row), src_buf, GOLDEN_ELEMS);

  for (uint32_t r = 0; r + 1 < rows; ++r) {
    uint32_t last = spm[(base_row + r) * ROW_WORDS + 8];
    uint32_t first = spm[(base_row + r + 1) * ROW_WORDS + 0];
    if (last != first) {
      printf("  row %d bank8=0x%08x != row %d bank0=0x%08x\n", r, last, r + 1,
             first);
      ok = 0;
    }
  }
  printf("  %-34s : %s\n", "bank-8 duplication invariant",
         ok ? "PASS" : "FAIL");
  return ok;
}

/* ------------------------------------------------------------------ */
/* 5. cost per word - the number the roofline model needs              */
/* ------------------------------------------------------------------ */
static void measure(void) {
  uint32_t addr = get_addr_start(0);
  uint32_t t0, t1, wr_cy, rd_cy;

  fill_src(0);

  START_PERFCNT(0x1)
  t0 = read_mcycle();
  SPM_PUT(addr, src_buf, GOLDEN_ELEMS);
  t1 = read_mcycle();
  STOP_PERFCNT(0x1)
  wr_cy = t1 - t0;

  START_PERFCNT(0x2)
  t0 = read_mcycle();
  SPM_GET(dst_buf, addr, GOLDEN_ELEMS);
  t1 = read_mcycle();
  STOP_PERFCNT(0x2)
  rd_cy = t1 - t0;

  printf("\n*** transfer cost (%s), %d payload words\n", SPM_BACKEND,
         GOLDEN_ELEMS);
  printf("***   put : %6d cycles -> %d.%02d cycles/word\n", wr_cy,
         wr_cy / GOLDEN_ELEMS, (100u * wr_cy / GOLDEN_ELEMS) % 100u);
  printf("***   get : %6d cycles -> %d.%02d cycles/word\n", rd_cy,
         rd_cy / GOLDEN_ELEMS, (100u * rd_cy / GOLDEN_ELEMS) % 100u);
}

int main(int argc, char *argv[]) {
  int testOK = 1;

  (void)argc;
  (void)argv;

  printf("***\n");
  printf("***  BANK_DATA_WIDTH     = 0x%08x\n", BANK_DATA_WIDTH);
  printf("***  NUM_BANKS           = 0x%08x\n", NUM_BANKS);
  printf("***  WIDE_ADDR_ALIGNMENT = 0x%08x\n", WIDE_ADDR_ALIGNMENT);
  printf("***  backend             = %s\n", SPM_BACKEND);
  printf("***  payload words       = %d\n", GOLDEN_ELEMS);
  printf("***\n");

  testOK = test_roundtrip_row0() && testOK;
  testOK = test_roundtrip_row2() && testOK;
  testOK = test_chained_blocks() && testOK;
  testOK = test_bank8_duplication() && testOK;

  measure();

  printf("\n*** spm_test: %s ***\n", testOK ? "PASS" : "FAIL");

#ifdef RV_DM_TEST
  while (1) {
    asm volatile("wfi");
  }
#else
  return testOK ? 0x0 : 0xBADC0FFE;
#endif
}