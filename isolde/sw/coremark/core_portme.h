/*
 * CoreMark port for the ISOLDE AIDA cluster (aida_tb / ZCU104).
 *
 * Based on EEMBC's barebones port and lowRISC's Ibex simple_system port
 * (examples/sw/benchmarks/coremark/ibex).
 *
 * Copyright 2018 Embedded Microprocessor Benchmark Consortium (EEMBC)
 * Licensed under the Apache License, Version 2.0.
 * SPDX-License-Identifier: Apache-2.0
 */
#ifndef CORE_PORTME_H
#define CORE_PORTME_H

#include <stddef.h>

/* ---------------------------------------------------------------------- */
/* AIDA configuration (override with TEST_CPPFLAGS)                        */
/* ---------------------------------------------------------------------- */

/* Iterations. 10 keeps the Verilator run to about two minutes. On the board,
 * a reportable result needs >= 10 s: about 3000 at 80 MHz. */
#ifndef ITERATIONS
#define ITERATIONS 10
#endif

/* Core clock, used only to convert cycles to seconds for CoreMark's
 * "Total time" and its 10-second rule. 80 MHz is the ZCU104 clock wizard
 * output (isolde/system/fpga/ips/xilinx_clk_mngr, 300 MHz * 4 / 15).
 * CoreMark/MHz does not depend on it. */
#ifndef COREMARK_CLOCK_HZ
#define COREMARK_CLOCK_HZ 80000000u
#endif

/* 1: enable the Ibex I-cache (cpuctrlsts[0]) in portable_init. */
#ifndef COREMARK_ICACHE
#define COREMARK_ICACHE 0
#endif

/* 1: point mtvec at crt0's vector table in portable_init, so a trap prints
 * EXCEPTION/MEPC/MCAUSE/MTVAL instead of hanging (debug-ROM builds reset
 * with mtvec = 0x1, an unmapped vector base). One CSR write; opt-in. */
#ifndef COREMARK_TRAP_HANDLER
#define COREMARK_TRAP_HANDLER 0
#endif

/* ---------------------------------------------------------------------- */
/* Platform features                                                       */
/* ---------------------------------------------------------------------- */

/* No soft-float runtime is linked (-nostdlib, no compiler-rt), so CoreMark
 * runs with integer seconds; the port prints CoreMark/MHz in fixed point. */
#ifndef HAS_FLOAT
#define HAS_FLOAT 0
#endif
#ifndef HAS_TIME_H
#define HAS_TIME_H 0
#endif
#ifndef USE_CLOCK
#define USE_CLOCK 0
#endif
#ifndef HAS_STDIO
#define HAS_STDIO 0
#endif
#ifndef HAS_PRINTF
#define HAS_PRINTF 0
#endif

/* Strings reported with the result (CoreMark run rules: report the compiler
 * and the flags). Override COMPILER_FLAGS if you change OPT_LEVEL or flags. */
#ifndef COMPILER_VERSION
#if defined(__clang__)
#define COMPILER_VERSION "Clang " __clang_version__
#elif defined(__GNUC__)
#define COMPILER_VERSION "GCC " __VERSION__
#else
#define COMPILER_VERSION "unknown"
#endif
#endif
#ifndef COMPILER_FLAGS
#define COMPILER_FLAGS                                                      \
  "-O3 -march=rv32im_zicsr -mabi=ilp32 -mcmodel=medany -ffreestanding "    \
  "-ffunction-sections -fdata-sections -fvisibility=hidden "                \
  "(isolde/system/bsp default)"
#endif

/* ---------------------------------------------------------------------- */
/* Data types                                                              */
/* ---------------------------------------------------------------------- */
typedef signed short   ee_s16;
typedef unsigned short ee_u16;
typedef signed int     ee_s32;
typedef double         ee_f32;
typedef unsigned char  ee_u8;
typedef unsigned int   ee_u32;
typedef ee_u32         ee_ptr_int;
typedef size_t         ee_size_t;
#ifndef NULL
#define NULL ((void *)0)
#endif

#define align_mem(x) (void *)(4 + (((ee_ptr_int)(x)-1) & ~3))

#define CORETIMETYPE ee_u32
typedef ee_u32 CORE_TICKS;

#ifndef SEED_METHOD
#define SEED_METHOD SEED_VOLATILE
#endif
/* Where the 2000-byte work area lives. MEM_STACK (default, as lowRISC's
 * port) needs about 2.5 KiB of stack; -DMEM_METHOD=MEM_STATIC moves it to
 * data RAM, for bitstreams with a small stack SRAM (platform "aida": 2 KiB). */
#ifndef MEM_METHOD
#define MEM_METHOD MEM_STACK
#endif
#ifndef MEM_LOCATION
#if MEM_METHOD == MEM_STATIC
#define MEM_LOCATION "STATIC"
#else
#define MEM_LOCATION "STACK"
#endif
#endif
#ifndef MULTITHREAD
#define MULTITHREAD 1
#define USE_PTHREAD 0
#define USE_FORK 0
#define USE_SOCKET 0
#endif
#ifndef MAIN_HAS_NOARGC
#define MAIN_HAS_NOARGC 1
#endif
#ifndef MAIN_HAS_NORETURN
#define MAIN_HAS_NORETURN 0
#endif

extern ee_u32 default_num_contexts;

typedef struct CORE_PORTABLE_S {
  ee_u8 portable_id;
} core_portable;

void portable_init(core_portable *p, int *argc, char *argv[]);
void portable_fini(core_portable *p);

#if !defined(PROFILE_RUN) && !defined(PERFORMANCE_RUN) && !defined(VALIDATION_RUN)
#if (TOTAL_DATA_SIZE == 1200)
#define PROFILE_RUN 1
#elif (TOTAL_DATA_SIZE == 2000)
#define PERFORMANCE_RUN 1
#else
#define VALIDATION_RUN 1
#endif
#endif

int ee_printf(const char *fmt, ...);

#endif /* CORE_PORTME_H */
