/*
 ****************************************************************************
 *
 *                   "DHRYSTONE" Benchmark Program
 *                   -----------------------------
 *
 *  Version:    C, Version 2.1
 *  File:       dhry.h (part 1 of 3)
 *  Date:       May 25, 1988
 *  Author:     Reinhold P. Weicker
 *
 *  Original Version (in Ada) published in "Communications of the ACM"
 *  vol. 27., no. 10 (Oct. 1984), pp. 1013 - 1030.
 *
 ****************************************************************************
 *
 *  ISOLDE / AIDA port (aida_tb, isolde/system).
 *
 *  This port keeps the statements executed inside the measurement loop
 *  exactly as in Dhrystone 2.1 and follows Weicker's ground rules:
 *
 *    - Separate compilation: dhry_1.c (Pack_1: main, Proc_1..Proc_5) and
 *      dhry_2.c (Pack_2: Proc_6..Proc_8, Func_1..Func_3) are two translation
 *      units. Do not build with LTO (ENABLE_LTO must stay 0).
 *    - No procedure merging: every Proc_x / Func_x is marked noinline, so
 *      calls inside dhry_1.c (Proc_1..Proc_5) are not merged into main
 *      either. The build log check in README.md verifies this.
 *    - strcpy / strcmp / memcpy (structure assignment) are library calls.
 *      With -ffreestanding the compiler does not expand them inline.
 *
 *  Differences from the reference distribution, none inside the loop:
 *    - Records are static objects in data memory instead of malloc()'d
 *      (there is no heap in this BSP); both live in data RAM.
 *    - Time is measured in clock cycles with the AIDA performance counter
 *      (aida_perfcnt, MMIO 0x8000000C), cross-checked against the Ibex
 *      mcycle / minstret CSRs.
 *    - An untimed warm-up pass runs first so the Ibex I-cache is filled.
 *    - main() returns the number of self-check mismatches, so the
 *      testbench reports "errors=00000000" only for a correct run.
 *
 ****************************************************************************
 */
#ifndef DHRY_H
#define DHRY_H

#include <bsp/tinyprintf.h>
#include <bsp/simple_system_common.h>
#include <bsp/simple_system_regs.h>

/* ---------------------------------------------------------------------- */
/* Configuration                                                           */
/* ---------------------------------------------------------------------- */

#ifndef DHRY_RUNS
#define DHRY_RUNS       1000    /* timed iterations                       */
#endif

#ifndef DHRY_WARMUP_RUNS
#define DHRY_WARMUP_RUNS  10    /* untimed iterations (I-cache warm-up)   */
#endif

#ifndef DHRY_ICACHE
#define DHRY_ICACHE        0    /* 1: enable the Ibex I-cache before the run */
#endif

#define DHRY_PERFCNT_ID   0xD21 /* id written to aida_perfcnt / perfcnt.csv */

/* VAX 11/780 = 1757 Dhrystones per second = 1 MIPS (DMIPS reference). */
#define DHRY_VAX_DPS      1757u

/* ---------------------------------------------------------------------- */
/* Compiler and system dependent definitions                               */
/* ---------------------------------------------------------------------- */

#define DHRY_NOINLINE __attribute__((noinline))

#ifdef NOSTRUCTASSIGN
#define structassign(d, s)      memcpy(&(d), &(s), sizeof(d))
#else
#define structassign(d, s)      d = s
#endif

#ifdef NOENUM
#define Ident_1 0
#define Ident_2 1
#define Ident_3 2
#define Ident_4 3
#define Ident_5 4
typedef int Enumeration;
#else
typedef enum { Ident_1, Ident_2, Ident_3, Ident_4, Ident_5 } Enumeration;
#endif

/* Library functions used by the benchmark. Declared here instead of
 * including <string.h> so the build does not depend on the sysroot
 * headers; the implementations come from the toolchain libc (-lc). */
char *strcpy(char *dst, const char *src);
int   strcmp(const char *s1, const char *s2);
void *memcpy(void *dst, const void *src, __SIZE_TYPE__ n);

/* General definitions */
#define Null  0
#define true  1
#define false 0

typedef int   One_Thirty;
typedef int   One_Fifty;
typedef char  Capital_Letter;
typedef int   Boolean;
typedef char  Str_30[31];
typedef int   Arr_1_Dim[50];
typedef int   Arr_2_Dim[50][50];

typedef struct record {
  struct record *Ptr_Comp;
  Enumeration    Discr;
  union {
    struct {
      Enumeration Enum_Comp;
      int         Int_Comp;
      char        Str_Comp[31];
    } var_1;
    struct {
      Enumeration E_Comp_2;
      char        Str_2_Comp[31];
    } var_2;
    struct {
      char Ch_1_Comp;
      char Ch_2_Comp;
    } var_3;
  } variant;
} Rec_Type, *Rec_Pointer;

/* "register" approximation, see the Dhrystone 2.1 documentation.
 * Default results are those without register declarations. */
#ifndef REG
#define REG
#define DHRY_REG_ATTR 0
#else
#define DHRY_REG_ATTR 1         /* built with -DREG=register */
#endif

/* Global variables (defined in dhry_1.c) */
extern Rec_Pointer Ptr_Glob, Next_Ptr_Glob;
extern int         Int_Glob;
extern Boolean     Bool_Glob;
extern char        Ch_1_Glob, Ch_2_Glob;
extern int         Arr_1_Glob[50];
extern int         Arr_2_Glob[50][50];

/* Pack_1 (dhry_1.c) */
DHRY_NOINLINE void Proc_1(REG Rec_Pointer Ptr_Val_Par);
DHRY_NOINLINE void Proc_2(One_Fifty *Int_Par_Ref);
DHRY_NOINLINE void Proc_3(Rec_Pointer *Ptr_Ref_Par);
DHRY_NOINLINE void Proc_4(void);
DHRY_NOINLINE void Proc_5(void);

/* Pack_2 (dhry_2.c) */
DHRY_NOINLINE void Proc_6(Enumeration Enum_Val_Par, Enumeration *Enum_Ref_Par);
DHRY_NOINLINE void Proc_7(One_Fifty Int_1_Par_Val, One_Fifty Int_2_Par_Val,
                          One_Fifty *Int_Par_Ref);
DHRY_NOINLINE void Proc_8(Arr_1_Dim Arr_1_Par_Ref, Arr_2_Dim Arr_2_Par_Ref,
                          int Int_1_Par_Val, int Int_2_Par_Val);
DHRY_NOINLINE Enumeration Func_1(Capital_Letter Ch_1_Par_Val,
                                 Capital_Letter Ch_2_Par_Val);
DHRY_NOINLINE Boolean Func_2(Str_30 Str_1_Par_Ref, Str_30 Str_2_Par_Ref);
DHRY_NOINLINE Boolean Func_3(Enumeration Enum_Par_Val);

#endif /* DHRY_H */
