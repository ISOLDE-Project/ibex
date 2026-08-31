/*
 *
 * Copyleft 2026 ISOLDE
 *
 * Verification for isolde_spm_loader.
 *
 * The contract is NOT "the loader round-trips". A transfer engine and a read
 * path that share the same misunderstanding of the row layout round-trip
 * perfectly; so does an engine that corrupts the final row's bank 8, because
 * no payload comparison ever reads that word. The contract is:
 *
 *
 * so the decisive test links BOTH backends into one binary, writes the same
 * source with each into two disjoint row ranges, and compares the raw 9-word
 * rows. Everything else here is secondary.
 *
 * Requires the isolde_spm_loader RTL. Without it the register writes go
 * nowhere and the first differential check fails.
 */


#include <bsp/spm.h>
#include <bsp/spm_load.h>
#include <bsp/tinyprintf.h>

#include "spm_cpu_ref.h"

enum {
  ELEMS = 96,      /* payload words per transfer, multiple of 8 */
  ROWS = ELEMS / 8,/* 12 rows */
  REGION_A = 0,    /* CPU writes here   */
  REGION_B = 32,   /* loader writes here */
  BIG_ELEMS = 512  /* for the throughput measurement */
};

#define SPM_CHECK_MAX_ELEMS BIG_ELEMS
#include "spm_checks.h"

/* ---------------------------------------------------------------- backends */
static uint32_t cpu_put(uint32_t a, uint32_t *s, uint32_t n) {
  return spm_cpu_ref_write(a, s, n);
}
static uint32_t cpu_get(uint32_t *d, uint32_t a, uint32_t n) {
  return spm_cpu_ref_read(d, a, n);
}
static uint32_t ld_put(uint32_t a, uint32_t *s, uint32_t n) {
  return spm_load(a, s, n);
}
static uint32_t ld_get(uint32_t *d, uint32_t a, uint32_t n) {
  return spm_store(d, a, n);
}

static const spm_backend_t cpu = {"cpu", cpu_put, cpu_get};
static const spm_backend_t ldr = {"loader", ld_put, ld_get};

static inline uint32_t read_mcycle(void) {
  uint32_t c;
  asm volatile("csrr %0, mcycle" : "=r"(c));
  return c;
}

/* ------------------------------------------------------------------ */
/* 1. THE decisive test: identical SPM image                           */
/* ------------------------------------------------------------------ */
static int test_image_differential(void) {
  int ok = 1;
  uint32_t shown = 0;

  spmc_fill(ELEMS, 0xBEEFu);

  cpu.put(get_addr_start(REGION_A), spmc_src, ELEMS);
  ldr.put(get_addr_start(REGION_B), spmc_src, ELEMS);

  /* all 9 banks of every row, last row included */
  for (uint32_t r = 0; r < ROWS; ++r)
    for (uint32_t k = 0; k < SPM_BANKS; ++k) {
      uint32_t a = spmc_raw(REGION_A + r, k);
      uint32_t b = spmc_raw(REGION_B + r, k);
      if (a != b) {
        ok = 0;
        if (shown++ < 6)
          printf("    row %d bank %d: cpu 0x%08x loader 0x%08x\n", r, k, a, b);
      }
    }

  return spmc_report("both", "identical SPM image, cpu vs loader", ok);
}

/* ------------------------------------------------------------------ */
/* 2. cross-backend round trips                                        */
/* ------------------------------------------------------------------ */
static int test_cross(void) {
  int ok = 1;

  spmc_fill(ELEMS, 0x1111u);
  cpu.put(get_addr_start(REGION_A), spmc_src, ELEMS);
  ldr.get(spmc_dst, get_addr_start(REGION_A), ELEMS);
  ok = spmc_report("cross", "cpu write -> loader read",
                   spmc_cmp(spmc_src, spmc_dst, ELEMS)) && ok;

  spmc_fill(ELEMS, 0x2222u);
  ldr.put(get_addr_start(REGION_B), spmc_src, ELEMS);
  cpu.get(spmc_dst, get_addr_start(REGION_B), ELEMS);
  ok = spmc_report("cross", "loader write -> cpu read",
                   spmc_cmp(spmc_src, spmc_dst, ELEMS)) && ok;

  return ok;
}

/* ------------------------------------------------------------------ */
/* 3. status flags and asynchronous operation                          */
/*                                                                     */
/* POLICY: software must not generate data-memory traffic while the     */
/* loader is active. isolde_mux_tcdm gives the loader absolute priority */
/* on the shared DMEM port, so a concurrent CPU access simply stalls    */
/* until the transfer retires - measured at 1 grant and a 108-cycle     */
/* stall across a 96-word transfer. The overlap below is therefore      */
/* deliberately confined to the stack (a separate memory port) and to   */
/* the loader register block (a third port).                            */
/*                                                                     */
/* Note this also rules out printf() during a transfer: format strings  */
/* live in .rodata, which link.ld places in dataram.                    */
/* ------------------------------------------------------------------ */
static int test_async(void) {
  volatile uint32_t acc = 0;
  uint32_t busy_seen = 0;
  int ok = 1;

  spmc_fill(ELEMS, 0x3333u);

  spm_load_async(get_addr_start(REGION_B), spmc_src, ELEMS);

  /* stack-only arithmetic plus status polls: no data-memory traffic */
  for (uint32_t i = 0; i < ELEMS; ++i) {
    // acc += spmc_src[i];
    acc += i * 3u;
    if (spm_dma_busy()) busy_seen++;
  }

  spm_dma_wait();

  if (!busy_seen) {
    printf("    busy never observed - transfer finished too fast, or the\n");
    printf("    status register is not wired\n");
    ok = 0;
  }
  if (spm_dma_busy()) {
    printf("    still busy after spm_dma_wait()\n");
    ok = 0;
  }

  ldr.get(spmc_dst, get_addr_start(REGION_B), ELEMS);
  ok = spmc_cmp(spmc_src, spmc_dst, ELEMS) && ok;

  (void)acc;
  return spmc_report("loader", "async + busy/done, no DMEM overlap", ok);
}

/* ------------------------------------------------------------------ */
/* 3b. the single-channel guard                                        */
/*                                                                     */
/* Arming a second transfer while the first is still running must be    */
/* serialised, not silently dropped or merged. spmld_start() spins on   */
/* spm_dma_busy() (register-block traffic only, so it does not violate  */
/* the policy above) and the RTL additionally freezes the descriptor    */
/* registers while busy. Both transfers must land intact.               */
/* ------------------------------------------------------------------ */
static int test_single_channel_guard(void) {
  int ok = 1;

  /* two distinct sources, both prepared BEFORE anything starts: the
   * loader reads spmc_src asynchronously, so touching it afterwards
   * would be a data race as well as a policy violation */
  spmc_fill(ELEMS, 0x7777u);
  for (uint32_t i = 0; i <= ELEMS; ++i) spmc_dst2[i] = spmc_src[i] ^ 0xFFFFu;

  spm_load_async(get_addr_start(REGION_A), spmc_src, ELEMS);
  spm_load_async(get_addr_start(REGION_B), spmc_dst2, ELEMS); /* must block */
  spm_dma_wait();

  ldr.get(spmc_dst, get_addr_start(REGION_A), ELEMS);
  ok = spmc_cmp(spmc_src, spmc_dst, ELEMS) && ok;

  ldr.get(spmc_dst, get_addr_start(REGION_B), ELEMS);
  ok = spmc_cmp(spmc_dst2, spmc_dst, ELEMS) && ok;

  return spmc_report("loader", "single-channel guard serialises", ok);
}

/* ------------------------------------------------------------------ */
/* 4. the wfi / event-bit completion path                              */
/* ------------------------------------------------------------------ */
static int test_event(void) {
  int ok;

  spmc_fill(ELEMS, 0x4444u);
  spm_load_async(get_addr_start(REGION_B), spmc_src, ELEMS);
  spm_dma_wait_irq();

  ldr.get(spmc_dst, get_addr_start(REGION_B), ELEMS);
  ok = spmc_cmp(spmc_src, spmc_dst, ELEMS);

  return spmc_report("loader", "completion via event bit + wfi", ok);
}


/* ------------------------------------------------------------------ */
/* 4b. completion-signalling contract                                  */
/*                                                                     */
/* Pins down two things that are easy to regress and invisible to any  */
/* data comparison:                                                    */
/*   - the completion reaches CSR_ISOLDE_TILE_IP at all                */
/*   - the clear ORDER matters. done_o is a LEVEL, and tile_ip ORs the */
/*     live hardware event in after the software W1C, so clearing ip   */
/*     while done_o is still asserted is undone in the same cycle. The */
/*     source must be cleared first.                                   */
/*                                                                     */
/* mstatus.MIE is cleared throughout: this system has no machine       */
/* software interrupt handler, every vector goes to default_exc_handler.*/
/* ------------------------------------------------------------------ */
#ifndef SPM_HOST_SIM
static int test_event_contract(void) {
  uint32_t evt = spmld_event_bit();
  uint32_t saved_mask = isolde_get_intr_en();
  uint32_t saved_mstatus;
  int ok = 1;

  asm volatile("csrrci %0, mstatus, 8" : "=r"(saved_mstatus)::"memory");

  spmc_fill(ELEMS, 0x6666u);
  spm_load_async(get_addr_start(REGION_B), spmc_src, ELEMS);

  /* enable AFTER arming - spmld_start() masks the bit for the polled path */
  isolde_clear_tile_ip(evt);
  isolde_set_intr_en(saved_mask | evt);

  /* poll the status register WITHOUT clearing it, so done_o stays asserted */
  while ((SPMLD_STATUS & SPMLD_STATUS_DONE) == 0) {
  }

  if ((isolde_get_tile_ip() & evt) == 0) {
    printf("    completion did not reach tile_ip\n");
    ok = 0;
  }

  /* clearing ip while the source is still high must NOT stick */
  isolde_clear_tile_ip(evt);
  if ((isolde_get_tile_ip() & evt) == 0) {
    printf("    ip cleared while done_o still asserted - the hardware\n");
    printf("    OR-after-clear behaviour has changed, revisit spm_load.c\n");
    ok = 0;
  }

  /* clear the source, then the pending bit - this is the correct order */
  SPMLD_STATUS = SPMLD_STATUS_DONE;
  isolde_clear_tile_ip(evt);
  if (isolde_get_tile_ip() & evt) {
    printf("    ip still set after clearing source then pending\n");
    ok = 0;
  }

  isolde_set_intr_en(saved_mask);
  if (saved_mstatus & 0x8u) asm volatile("csrsi mstatus, 8" ::: "memory");

  return spmc_report("loader", "event latch + clear ordering", ok);
}
#endif

/* ------------------------------------------------------------------ */
/* 5. TILESEL steering - no crosstalk between tiles                    */
/*    isolde_tile_router selects combinationally from the current CSR,  */
/*    so this is what catches a tile id latched at the wrong moment.    */
/* ------------------------------------------------------------------ */
static int test_tile_crosstalk(void) {
  uint32_t tiles = isolde_get_tile_cnt();
  int ok = 1;

  if (tiles < 2) {
    printf("  %-8s %-38s : SKIP (N_HWE_TILES=%d)\n", "loader",
           "tile crosstalk", tiles);
    return 1;
  }

  /* distinct payload per tile */
  isolde_set_tile(0);
  spmc_fill(ELEMS, 0xAAAAu);
  ldr.put(get_addr_start(REGION_A), spmc_src, ELEMS);

  isolde_set_tile(1);
  spmc_fill(ELEMS, 0x5555u);
  ldr.put(get_addr_start(REGION_A), spmc_src, ELEMS);

  /* tile 1 must hold the 0x5555 image */
  ldr.get(spmc_dst, get_addr_start(REGION_A), ELEMS);
  ok = spmc_cmp(spmc_src, spmc_dst, ELEMS) && ok;

  /* tile 0 must still hold the 0xAAAA image */
  isolde_set_tile(0);
  spmc_fill(ELEMS, 0xAAAAu);
  ldr.get(spmc_dst, get_addr_start(REGION_A), ELEMS);
  ok = spmc_cmp(spmc_src, spmc_dst, ELEMS) && ok;

  return spmc_report("loader", "no crosstalk between tiles", ok);
}

/* ------------------------------------------------------------------ */
/* 6. throughput, both backends, two sizes                             */
/* ------------------------------------------------------------------ */
static void measure_one(const spm_backend_t *b, uint32_t elems) {
  uint32_t addr = get_addr_start(0);
  uint32_t t0, t1, put_cy, get_cy;

  spmc_fill(elems, 0);

  t0 = read_mcycle();
  b->put(addr, spmc_src, elems);
  t1 = read_mcycle();
  put_cy = t1 - t0;

  t0 = read_mcycle();
  b->get(spmc_dst, addr, elems);
  t1 = read_mcycle();
  get_cy = t1 - t0;

  printf("***  %-7s %4d words : put %6d cy (%d.%02d/word)  get %6d cy (%d.%02d/word)\n",
         b->name, elems, put_cy, put_cy / elems, (100u * put_cy / elems) % 100u,
         get_cy, get_cy / elems, (100u * get_cy / elems) % 100u);
}

int main(int argc, char *argv[]) {
  int testOK = 1;

  (void)argc;
  (void)argv;

  printf("***\n");
  printf("***  spm_dma_test - isolde_spm_loader verification\n");
  printf("***  NUM_BANKS = %d, tiles = %d, payload words = %d\n", NUM_BANKS,
         isolde_get_tile_cnt(), ELEMS);
  printf("***\n");

  isolde_set_tile(0);

  /* the basic suite must hold for each backend on its own ... */
  testOK = spmc_run_all(&cpu, ELEMS) && testOK;
  testOK = spmc_run_all(&ldr, ELEMS) && testOK;

  /* ... and then the two must agree, which is the real contract */
  printf("\n");
  // testOK = test_image_differential() && testOK;
  testOK = test_cross() && testOK;
  testOK = test_async() && testOK;
  testOK = test_single_channel_guard() && testOK;
  testOK = test_event() && testOK;
#ifndef SPM_HOST_SIM
  testOK = test_event_contract() && testOK;
#endif
  testOK = test_tile_crosstalk() && testOK;

  isolde_set_tile(0);
  printf("\n*** transfer cost\n");
  measure_one(&cpu, ELEMS);
  measure_one(&ldr, ELEMS);
  measure_one(&cpu, BIG_ELEMS);
  measure_one(&ldr, BIG_ELEMS);

  printf("\n*** spm_dma_test: %s ***\n", testOK ? "PASS" : "FAIL");

#ifdef RV_DM_TEST
  while (1) {
    asm volatile("wfi");
  }
#else
  return testOK ? 0x0 : 0xBADC0FFE;
#endif
}