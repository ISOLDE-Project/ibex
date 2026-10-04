/*
 * CoreMark port for the ISOLDE AIDA cluster (aida_tb / ZCU104).
 *
 * Based on EEMBC's barebones port and lowRISC's Ibex simple_system port
 * (examples/sw/benchmarks/coremark/ibex).
 *
 * Timing
 *   - Only the aida_perfcnt MMIO block (0x8000000C) is used: no CSR reads.
 *     start_time()/stop_time() bracket exactly the timed region that
 *     core_main.c defines; each writes the measurement id (0xC0E) to
 *     PERFCNT+0x00 (first write starts, second stops). get_time() then
 *     reads the elapsed cycles from PERFCNT+0x04.
 *   - The same block also reports instruction-memory reads and data/stack
 *     memory reads and writes for the timed region; they are printed too.
 *   - time_in_secs() divides by COREMARK_CLOCK_HZ, which only matters for
 *     CoreMark's 10-second rule.
 *   - The Ibex I-cache is only touched (a CSR write) when built with
 *     COREMARK_ICACHE=1; by default the port executes no CSR instruction.
 *
 * Result and exit code
 *   core_main.c (unmodified) always returns 0, so the port watches what it
 *   prints: a CRC mismatch, a data-type error, or seeds it cannot validate
 *   make the run fail. A run shorter than 10 s is reported as "not
 *   reportable" but still passes, so the short Verilator run is a valid
 *   functional test. portable_fini() exits with the number of failures,
 *   which aida_tb prints as errors=XXXXXXXX.
 *
 * Copyright 2018 Embedded Microprocessor Benchmark Consortium (EEMBC)
 * Licensed under the Apache License, Version 2.0.
 * SPDX-License-Identifier: Apache-2.0
 */
#include <stdarg.h>

#include "coremark.h"

#include <bsp/simple_system_common.h>
#include <bsp/simple_system_regs.h>
#include <bsp/tinyprintf.h>


#define COREMARK_PERFCNT_ID 0xC0Eu

/* ---------------------------------------------------------------------- */
/* Progress beacon                                                         */
/*                                                                         */
/* A few words in data RAM that say how far the run got. The debugger can   */
/* read them over the system bus WITHOUT halting the core (halting a running */
/* program is unreliable on this SoC), e.g. with coremark_peek.tcl:          */
/*   riscv set_mem_access sysbus ; read_memory <addr> 32 6                   */
/* The address is printed by portable_init and is in the .map file.          */
/* ---------------------------------------------------------------------- */
#define BEACON_MAGIC 0xC0E5BEACu
enum {
  STAGE_BOOT      = 0,   /* image loaded, port not entered yet             */
  STAGE_INIT      = 1,   /* portable_init() ran                            */
  STAGE_TIMING    = 2,   /* start_time(): benchmark iterations running     */
  STAGE_TIMED     = 3,   /* stop_time(): iterations done, CRC/report next  */
  STAGE_REPORT    = 4,   /* portable_fini() entered                        */
  STAGE_EXIT      = 5    /* about to _Exit(failures)                       */
};
struct coremark_beacon {
  ee_u32 magic;          /* BEACON_MAGIC once portable_init has run        */
  ee_u32 stage;          /* STAGE_*                                        */
  ee_u32 printf_calls;   /* ee_printf calls so far                         */
  ee_u32 cycles;         /* aida_perfcnt cycles of the timed run           */
  ee_u32 failures;       /* exit code, set at STAGE_EXIT                   */
  ee_u32 last_fmt;       /* address of the last ee_printf format string    */
};
volatile struct coremark_beacon coremark_beacon;

static inline void beacon_stage(ee_u32 stage)
{
  asm volatile("" : : : "memory");
  coremark_beacon.stage = stage;
  asm volatile("" : : : "memory");
}

#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PERFORMANCE_RUN
volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PROFILE_RUN
volatile ee_s32 seed1_volatile = 0x8;
volatile ee_s32 seed2_volatile = 0x8;
volatile ee_s32 seed3_volatile = 0x8;
#endif
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;

ee_u32 default_num_contexts = 1;

/* ---------------------------------------------------------------------- */
/* Counters                                                                */
/* ---------------------------------------------------------------------- */

static inline void perfcnt_toggle(ee_u32 id)
{
  /* First write starts the aida_perfcnt measurement, second stops it. */
  asm volatile("" : : : "memory");
  *(volatile ee_u32 *)MMADDR_PERF_COUNTERS = id;
  asm volatile("" : : : "memory");
}

/* Result registers, valid once the stop write has been taken. */
static inline ee_u32 perfcnt_cycles(void)
{
  return *(volatile ee_u32 *)(MMADDR_PERF_COUNTERS + 4);
}

static inline ee_u32 perfcnt_reg(ee_u32 offset)
{
  return *(volatile ee_u32 *)(MMADDR_PERF_COUNTERS + offset);
}

#define PERFCNT_IMEM_RD   0x0Cu
#define PERFCNT_DMEM_WR   0x10u
#define PERFCNT_DMEM_RD   0x14u
#define PERFCNT_STACK_WR  0x18u
#define PERFCNT_STACK_RD  0x1Cu

static int measured;           /* a start/stop pair has completed */

void start_time(void)
{
  beacon_stage(STAGE_TIMING);
  perfcnt_toggle(COREMARK_PERFCNT_ID);           /* start */
}

void stop_time(void)
{
  perfcnt_toggle(COREMARK_PERFCNT_ID);           /* stop  */
  measured = 1;
  beacon_stage(STAGE_TIMED);
}

/* Elapsed cycles of the last start/stop pair. aida_perfcnt latches the
 * difference in the cycle after the stop write, before any later load can
 * reach it, so reading straight after stop_time() is safe. */
CORE_TICKS get_time(void)
{
  return measured ? (CORE_TICKS)perfcnt_cycles() : 0;
}

secs_ret time_in_secs(CORE_TICKS ticks)
{
  return (secs_ret)ticks / (secs_ret)COREMARK_CLOCK_HZ;
}

/* ---------------------------------------------------------------------- */
/* ee_printf: tinyprintf, plus a look at what core_main.c reports           */
/* ---------------------------------------------------------------------- */

static int seen_known_run;     /* "... run parameters for coremark."     */
static int crc_errors;         /* "[%u]ERROR! list/matrix/state crc ..."  */
static int type_errors;        /* "ERROR: ee_xx is not ..."               */
static int cannot_validate;    /* unknown seeds                           */
static int short_run;          /* "ERROR! Must execute for at least 10 s" */

/* Tiny local string tests instead of libc strncmp/strstr: newlib's strstr
 * pulls in ~3 KB of code and a 1 KB stack frame (two-way search). */
static int starts_with(const char *s, const char *prefix)
{
  while (*prefix)
    if (*s++ != *prefix++)
      return 0;
  return 1;
}

static int contains(const char *s, const char *needle)
{
  for (; *s; ++s)
    if (starts_with(s, needle))
      return 1;
  return 0;
}

static void observe(const char *fmt)
{
  if (starts_with(fmt, "[%u]ERROR!"))
    crc_errors++;
  else if (starts_with(fmt, "ERROR: "))
    type_errors++;
  else if (starts_with(fmt, "ERROR! Must execute"))
    short_run = 1;
  else if (starts_with(fmt, "Cannot validate"))
    cannot_validate = 1;
  else if (contains(fmt, "parameters for coremark"))
    seen_known_run = 1;
}

int ee_printf(const char *fmt, ...)
{
  va_list va;
  coremark_beacon.printf_calls++;
  coremark_beacon.last_fmt = (ee_u32)fmt;
  observe(fmt);
  va_start(va, fmt);
  tfp_format(NULL, _putcf, fmt, va);
  va_end(va);
  return 0;
}

/* ---------------------------------------------------------------------- */
/* Fixed-point helpers (no soft-float / libgcc on this BSP)                */
/* ---------------------------------------------------------------------- */

static ee_u32 udiv64(unsigned long long n, unsigned long long d)
{
  unsigned long long r = 0, q = 0;
  if (d == 0)
    return 0;
  for (int i = 63; i >= 0; --i) {
    r = (r << 1) | ((n >> i) & 1u);
    q <<= 1;
    if (r >= d) {
      r -= d;
      q |= 1u;
    }
  }
  return (ee_u32)q;
}

static void print_milli(ee_u32 v)
{
  ee_printf("%u.%03u", v / 1000u, v % 1000u);
}

/* ---------------------------------------------------------------------- */
/* init / fini                                                             */
/* ---------------------------------------------------------------------- */

void portable_init(core_portable *p, int *argc, char *argv[])
{
  (void)argc;
  (void)argv;
#if COREMARK_TRAP_HANDLER
  /* With the debug ROM build (BootROMEnable=1) Ibex resets with
   * mtvec = 0x00000001, i.e. vector base 0x0, which is not mapped: any trap
   * then fetches from an address that never gets a grant, and the core hangs
   * and cannot be halted. Point mtvec at crt0's vector table instead, so a
   * trap prints EXCEPTION / MEPC / MCAUSE / MTVAL. (One CSR write; opt-in.) */
  {
    extern char _vectors_start[];
    asm volatile("csrw mtvec, %0" : : "r"((ee_u32)_vectors_start | 1u));
  }
#endif
  coremark_beacon.magic = BEACON_MAGIC;
  beacon_stage(STAGE_INIT);
  init_printf(NULL, _putcf);
  ee_printf("AIDA CoreMark platform init (ITERATIONS=%u, clock %u Hz)\n",
            (unsigned)ITERATIONS, (unsigned)COREMARK_CLOCK_HZ);
  if (sizeof(ee_ptr_int) != sizeof(ee_u8 *))
    ee_printf("ERROR! Please define ee_ptr_int to a type that holds a pointer!\n");
  if (sizeof(ee_u32) != 4)
    ee_printf("ERROR! Please define ee_u32 to a 32b unsigned type!\n");
#if COREMARK_ICACHE
  icache_enable(1);
  asm volatile(".word 0x0000100f" : : : "memory"); /* fence.i */
#endif
  ee_printf("Ibex I-cache     : %s (COREMARK_ICACHE=%d)\n",
            COREMARK_ICACHE ? "enabled" : "disabled", COREMARK_ICACHE);
  ee_printf("Progress beacon  : 0x%x (6 words; stage 1=init 2=timing 3=timed "
            "4=report 5=exit)\n", (unsigned)&coremark_beacon);
  ee_printf("Trap handler     : %s\n", COREMARK_TRAP_HANDLER
            ? "mtvec -> crt0 vectors (COREMARK_TRAP_HANDLER=1)"
            : "reset default (COREMARK_TRAP_HANDLER=0)");
  p->portable_id = 1;
}

void portable_fini(core_portable *p)
{
  ee_u32 cycles   = get_time();                   /* aida_perfcnt */
  ee_u32 iters    = (ee_u32)seed4_volatile;
  int    failures = crc_errors + type_errors + cannot_validate
                    + (seen_known_run ? 0 : 1);
  int    reportable;
  unsigned long long C = cycles, N = iters;

  p->portable_id = 0;
  beacon_stage(STAGE_REPORT);
  coremark_beacon.cycles = cycles;

  /* 10-second rule, evaluated on the same cycle count at COREMARK_CLOCK_HZ */
  reportable = !failures && (C >= 10ull * COREMARK_CLOCK_HZ);

  ee_printf("\nMeasured with aida_perfcnt (id 0x%x)\n", COREMARK_PERFCNT_ID);
  ee_printf("  Iterations:                       %u\n", iters);
  ee_printf("  Cycles (perfcnt):                 %u\n", cycles);
  ee_printf("  Instruction-memory reads:         %u\n", perfcnt_reg(PERFCNT_IMEM_RD));
  ee_printf("  Data-memory reads / writes:       %u / %u\n",
            perfcnt_reg(PERFCNT_DMEM_RD), perfcnt_reg(PERFCNT_DMEM_WR));
  ee_printf("  Stack-memory reads / writes:      %u / %u\n",
            perfcnt_reg(PERFCNT_STACK_RD), perfcnt_reg(PERFCNT_STACK_WR));

  if (cycles == 0 || iters == 0) {
    ee_printf("No cycle count: aida_perfcnt did not run\n");
    failures++;
  } else {
    ee_u32 cpi_x1000  = udiv64(C * 1000u, N);            /* cycles/iter  */
    /* CoreMark/MHz = iterations * 1e6 / cycles; x1000, rounded */
    ee_u32 cm_x1000   = udiv64(N * 1000000000ull + C / 2, C);
    /* seconds at COREMARK_CLOCK_HZ, x1000 */
    ee_u32 secs_x1000 = udiv64(C * 1000u, COREMARK_CLOCK_HZ);

    ee_printf("  Cycles per iteration:             "); print_milli(cpi_x1000); ee_printf("\n");
    ee_printf("  CoreMark/MHz:                     "); print_milli(cm_x1000);  ee_printf("\n");
    ee_printf("  Run time at %u Hz:          ", (unsigned)COREMARK_CLOCK_HZ);
    print_milli(secs_x1000);
    ee_printf(" s (CoreMark needs >= 10 s to report a score)\n");
    ee_printf("COREMARK_RESULT iterations=%u cycles=%u "
              "coremark_per_mhz_x1000=%u clock_hz=%u validated=%u reportable=%u\n",
              iters, cycles, cm_x1000, (unsigned)COREMARK_CLOCK_HZ,
              failures ? 0u : 1u, reportable ? 1u : 0u);
  }

  if (failures) {
    ee_printf("Validation: FAIL (crc errors %d, type errors %d%s%s)\n",
              crc_errors, type_errors,
              cannot_validate ? ", unknown seeds" : "",
              seen_known_run ? "" : ", no known run parameters");
  } else {
    ee_printf("Validation: PASS (CRCs match the known run parameters)\n");
    if (!reportable)
      ee_printf("Reportable: NO (run time < 10 s; increase ITERATIONS)%s\n",
                short_run ? " - core_main's \"ERROR! Must execute...\" "
                            "refers to this" : "");
    else
      ee_printf("Reportable: YES\n");
  }

  coremark_beacon.failures = (ee_u32)failures;
  beacon_stage(STAGE_EXIT);
  _Exit(failures);
}
