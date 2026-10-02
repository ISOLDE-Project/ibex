/*
 ****************************************************************************
 *
 *                   "DHRYSTONE" Benchmark Program
 *                   -----------------------------
 *
 *  Version:    C, Version 2.1
 *  File:       dhry_1.c (part 2 of 3)
 *  Date:       May 25, 1988
 *  Author:     Reinhold P. Weicker
 *
 *  ISOLDE / AIDA port: see dhry.h for the measurement rules.
 *
 ****************************************************************************
 */

#include "dhry.h"

/* Global Variables: */

Rec_Pointer Ptr_Glob, Next_Ptr_Glob;
int         Int_Glob;
Boolean     Bool_Glob;
char        Ch_1_Glob, Ch_2_Glob;
int         Arr_1_Glob[50];
int         Arr_2_Glob[50][50];

/* The reference version allocates both records with malloc(). There is no
 * heap in this BSP, so they are static objects in data memory instead. */
static Rec_Type Rec_Glob, Next_Rec_Glob;

static const Boolean Reg = DHRY_REG_ATTR;

/* ---------------------------------------------------------------------- */
/* Timing helpers (outside the measurement loop)                            */
/* ---------------------------------------------------------------------- */

static inline unsigned read_mcycle(void)
{
  unsigned v;
  asm volatile("csrr %0, mcycle" : "=r"(v) : : "memory");
  return v;
}

static inline unsigned read_minstret(void)
{
  unsigned v;
  asm volatile("csrr %0, minstret" : "=r"(v) : : "memory");
  return v;
}

static inline void perfcnt_toggle(unsigned id)
{
  /* First write starts the aida_perfcnt measurement, second stops it. */
  asm volatile("" : : : "memory");
  *(volatile unsigned *)MMADDR_PERF_COUNTERS = id;
  asm volatile("" : : : "memory");
}

static inline unsigned perfcnt_cycles(void)
{
  return *(volatile unsigned *)(MMADDR_PERF_COUNTERS + 4);
}

/* Ibex cpuctrlsts (CSR 0x7C0): bit 0 = icache_enable. The I-cache is
 * instantiated in isolde_cluster (ICache = 1) but disabled after reset;
 * build with DHRY_ICACHE=1 to turn it on (BSP icache_enable()) before the
 * warm-up pass. */
static inline unsigned read_cpuctrlsts(void)
{
  unsigned v;
  asm volatile("csrr %0, 0x7c0" : "=r"(v) : : "memory");
  return v;
}

/* 64-bit unsigned division by shift-subtract, so the report does not
 * depend on libgcc / compiler-rt (__udivdi3). Only used after the timed
 * loop. The quotients printed here always fit in 32 bits. */
static unsigned udiv64(unsigned long long n, unsigned long long d)
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
  return (unsigned)q;
}

/* Print v/1000 as "X.YYY". */
static void print_milli(unsigned v)
{
  printf("%u.%03u", v / 1000u, v % 1000u);
}

static int check_int(const char *name, int value, int expected)
{
  printf("%-21s%d\n", name, value);
  printf("        should be:   %d\n", expected);
  return value != expected;
}

static int check_chr(const char *name, char value, char expected)
{
  printf("%-21s%c\n", name, value);
  printf("        should be:   %c\n", expected);
  return value != expected;
}

static int check_str(const char *name, const char *value, const char *expected)
{
  printf("%-21s%s\n", name, value);
  printf("        should be:   %s\n", expected);
  return strcmp(value, expected) != 0;
}

/* ---------------------------------------------------------------------- */

int main(int argc, char *argv[])
/* main program, corresponds to procedures        */
/* Main and Proc_0 in the Ada version             */
{
        One_Fifty       Int_1_Loc;
  REG   One_Fifty       Int_2_Loc;
        One_Fifty       Int_3_Loc;
  REG   char            Ch_Index;
        Enumeration     Enum_Loc;
        Str_30          Str_1_Loc;
        Str_30          Str_2_Loc;
  REG   int             Run_Index;
  REG   int             Number_Of_Runs;

        /* volatile: keeps the compiler from unrolling the two passes into
         * two copies of the loop, so the warm-up pass really warms the
         * I-cache lines that the timed pass executes. */
        volatile int    Pass;
        int             Total_Runs = 0;
        unsigned        Cyc_Begin = 0, Cyc_End = 0;
        unsigned        Ins_Begin = 0, Ins_End = 0;
        int             Errors = 0;

  (void)argc;
  (void)argv;

  /* Initializations */

  Next_Ptr_Glob = &Next_Rec_Glob;
  Ptr_Glob      = &Rec_Glob;

  Ptr_Glob->Ptr_Comp                    = Next_Ptr_Glob;
  Ptr_Glob->Discr                       = Ident_1;
  Ptr_Glob->variant.var_1.Enum_Comp     = Ident_3;
  Ptr_Glob->variant.var_1.Int_Comp      = 40;
  strcpy (Ptr_Glob->variant.var_1.Str_Comp,
          "DHRYSTONE PROGRAM, SOME STRING");
  strcpy (Str_1_Loc, "DHRYSTONE PROGRAM, 1'ST STRING");

  Arr_2_Glob [8][7] = 10;
        /* Was missing in published program. Without this statement,    */
        /* Arr_2_Glob [8][7] would have an undefined value.             */
        /* Warning: With 16-Bit processors and Number_Of_Runs > 32000,  */
        /* overflow may occur for this array element.                   */

  /* Defensive initialisation; every value is overwritten in the loop.  */
  Int_1_Loc = Int_2_Loc = Int_3_Loc = 0;
  Enum_Loc  = Ident_1;
  Str_2_Loc[0] = '\0';

  printf ("\n");
  printf ("Dhrystone Benchmark, Version 2.1 (Language: C)\n");
  printf ("\n");
  if (Reg)
    printf ("Program compiled with 'register' attribute\n");
  else
    printf ("Program compiled without 'register' attribute\n");
  printf ("\n");
#if DHRY_ICACHE
  icache_enable (1);
  asm volatile (".word 0x0000100f" : : : "memory"); /* fence.i: invalidate */
#endif
  printf ("Ibex I-cache:            %s (cpuctrlsts=0x%x)\n",
          (read_cpuctrlsts () & 1u) ? "enabled" : "disabled",
          read_cpuctrlsts ());
  printf ("Warm-up runs (untimed):  %d\n", DHRY_WARMUP_RUNS);
  printf ("Execution starts, %d runs through Dhrystone\n", DHRY_RUNS);

  /* Pass 0: warm-up (fills the Ibex I-cache), not timed.
   * Pass 1: the measurement. The loop body is the unmodified Dhrystone 2.1
   * statement sequence. */
  for (Pass = 0; Pass < 2; ++Pass)
  {
    Number_Of_Runs = (Pass == 0) ? DHRY_WARMUP_RUNS : DHRY_RUNS;
    Total_Runs += Number_Of_Runs;

    if (Pass == 1)
    {
      perfcnt_toggle (DHRY_PERFCNT_ID);        /* start */
      Ins_Begin = read_minstret ();
      Cyc_Begin = read_mcycle ();
    }

    for (Run_Index = 1; Run_Index <= Number_Of_Runs; ++Run_Index)
    {
      Proc_5();
      Proc_4();
        /* Ch_1_Glob == 'A', Ch_2_Glob == 'B', Bool_Glob == true */
      Int_1_Loc = 2;
      Int_2_Loc = 3;
      strcpy (Str_2_Loc, "DHRYSTONE PROGRAM, 2'ND STRING");
      Enum_Loc = Ident_2;
      Bool_Glob = ! Func_2 (Str_1_Loc, Str_2_Loc);
        /* Bool_Glob == 1 */
      while (Int_1_Loc < Int_2_Loc)  /* loop body executed once */
      {
        Int_3_Loc = 5 * Int_1_Loc - Int_2_Loc;
          /* Int_3_Loc == 7 */
        Proc_7 (Int_1_Loc, Int_2_Loc, &Int_3_Loc);
          /* Int_3_Loc == 7 */
        Int_1_Loc += 1;
      } /* while */
        /* Int_1_Loc == 3, Int_2_Loc == 3, Int_3_Loc == 7 */
      Proc_8 (Arr_1_Glob, Arr_2_Glob, Int_1_Loc, Int_3_Loc);
        /* Int_Glob == 5 */
      Proc_1 (Ptr_Glob);
      for (Ch_Index = 'A'; Ch_Index <= Ch_2_Glob; ++Ch_Index)
                               /* loop body executed twice */
      {
        if (Enum_Loc == Func_1 (Ch_Index, 'C'))
            /* then, not executed */
          {
          Proc_6 (Ident_1, &Enum_Loc);
          strcpy (Str_2_Loc, "DHRYSTONE PROGRAM, 3'RD STRING");
          Int_2_Loc = Run_Index;
          Int_Glob = Run_Index;
          }
      }
        /* Int_1_Loc == 3, Int_2_Loc == 3, Int_3_Loc == 7 */
      Int_2_Loc = Int_2_Loc * Int_1_Loc;
      Int_1_Loc = Int_2_Loc / Int_3_Loc;
      Int_2_Loc = 7 * (Int_2_Loc - Int_3_Loc) - Int_1_Loc;
        /* Int_1_Loc == 1, Int_2_Loc == 13, Int_3_Loc == 7 */
      Proc_2 (&Int_1_Loc);
        /* Int_1_Loc == 5 */

    } /* loop "for Run_Index" */

    if (Pass == 1)
    {
      Cyc_End = read_mcycle ();
      Ins_End = read_minstret ();
      perfcnt_toggle (DHRY_PERFCNT_ID);        /* stop */
    }
  } /* loop "for Pass" */

  printf ("Execution ends\n");
  printf ("\n");
  printf ("Final values of the variables used in the benchmark:\n");
  printf ("\n");
  Errors += check_int ("Int_Glob:", Int_Glob, 5);
  Errors += check_int ("Bool_Glob:", Bool_Glob, 1);
  Errors += check_chr ("Ch_1_Glob:", Ch_1_Glob, 'A');
  Errors += check_chr ("Ch_2_Glob:", Ch_2_Glob, 'B');
  Errors += check_int ("Arr_1_Glob[8]:", Arr_1_Glob[8], 7);
  Errors += check_int ("Arr_2_Glob[8][7]:", Arr_2_Glob[8][7], Total_Runs + 10);
  printf ("        (Number_Of_Runs + 10, warm-up runs included)\n");
  printf ("Ptr_Glob->\n");
  printf ("  Ptr_Comp:          0x%x\n", (unsigned)Ptr_Glob->Ptr_Comp);
  printf ("        should be:   (implementation-dependent)\n");
  Errors += check_int ("  Discr:", Ptr_Glob->Discr, 0);
  Errors += check_int ("  Enum_Comp:", Ptr_Glob->variant.var_1.Enum_Comp, 2);
  Errors += check_int ("  Int_Comp:", Ptr_Glob->variant.var_1.Int_Comp, 17);
  Errors += check_str ("  Str_Comp:", Ptr_Glob->variant.var_1.Str_Comp,
                       "DHRYSTONE PROGRAM, SOME STRING");
  printf ("Next_Ptr_Glob->\n");
  printf ("  Ptr_Comp:          0x%x\n", (unsigned)Next_Ptr_Glob->Ptr_Comp);
  printf ("        should be:   (implementation-dependent), same as above\n");
  Errors += (Next_Ptr_Glob->Ptr_Comp != Ptr_Glob->Ptr_Comp);
  Errors += check_int ("  Discr:", Next_Ptr_Glob->Discr, 0);
  Errors += check_int ("  Enum_Comp:", Next_Ptr_Glob->variant.var_1.Enum_Comp, 1);
  Errors += check_int ("  Int_Comp:", Next_Ptr_Glob->variant.var_1.Int_Comp, 18);
  Errors += check_str ("  Str_Comp:", Next_Ptr_Glob->variant.var_1.Str_Comp,
                       "DHRYSTONE PROGRAM, SOME STRING");
  Errors += check_int ("Int_1_Loc:", Int_1_Loc, 5);
  Errors += check_int ("Int_2_Loc:", Int_2_Loc, 13);
  Errors += check_int ("Int_3_Loc:", Int_3_Loc, 7);
  Errors += check_int ("Enum_Loc:", Enum_Loc, 1);
  Errors += check_str ("Str_1_Loc:", Str_1_Loc, "DHRYSTONE PROGRAM, 1'ST STRING");
  Errors += check_str ("Str_2_Loc:", Str_2_Loc, "DHRYSTONE PROGRAM, 2'ND STRING");
  printf ("\n");

  /* ------------------------------------------------------------------ */
  /* Results                                                             */
  /* ------------------------------------------------------------------ */
  {
    unsigned Cycles      = perfcnt_cycles ();      /* aida_perfcnt        */
    unsigned Csr_Cycles  = Cyc_End - Cyc_Begin;    /* Ibex mcycle         */
    unsigned Instret     = Ins_End - Ins_Begin;    /* Ibex minstret       */
    unsigned long long N = (unsigned long long)DHRY_RUNS;
    unsigned long long C = (unsigned long long)Cycles;

    printf ("Measured with aida_perfcnt (id 0x%x)\n", DHRY_PERFCNT_ID);
    printf ("  Cycles (perfcnt):                 %u\n", Cycles);
    printf ("  Cycles (mcycle):                  %u\n", Csr_Cycles);
    printf ("  Instructions (minstret):          %u\n", Instret);

    if (Cycles == 0 || Cycles < (unsigned)(10 * DHRY_RUNS))
    {
      printf ("Measured time too small to obtain meaningful results\n");
      printf ("Please increase number of runs\n");
      Errors += 1;
    }
    else
    {
      unsigned long long I = (unsigned long long)Instret;
      /* cycles / run, x1000 */
      unsigned Cpr_x1000   = udiv64 (C * 1000u, N);
      /* instructions / run, x1000 */
      unsigned Ipr_x1000   = udiv64 (I * 1000u, N);
      /* IPC x1000 */
      unsigned Ipc_x1000   = udiv64 (I * 1000u, C);
      /* Dhrystones per second at 1 MHz = runs * 1e6 / cycles; x1000 */
      unsigned Dps_x1000   = udiv64 (N * 1000000000ull, C);
      /* DMIPS/MHz = (Dhrystones per second at 1 MHz) / 1757; x1000, rounded */
      unsigned Dmips_x1000 = udiv64 (N * 1000000000ull + C * DHRY_VAX_DPS / 2,
                                     C * DHRY_VAX_DPS);

      printf ("  Cycles per run:                   "); print_milli (Cpr_x1000);  printf ("\n");
      printf ("  Instructions per run:             "); print_milli (Ipr_x1000);  printf ("\n");
      printf ("  IPC:                              "); print_milli (Ipc_x1000);  printf ("\n");
      printf ("  Dhrystones per second per MHz:    "); print_milli (Dps_x1000);  printf ("\n");
      printf ("  DMIPS/MHz (1757 Dhrystones/s):    "); print_milli (Dmips_x1000); printf ("\n");
      printf ("DHRYSTONE_RESULT\n * runs=%d\n * cycles=%u\n * instret=%u\n * dmips_per_mhz_x1000=%u\n***\n",
              DHRY_RUNS, Cycles, Instret, Dmips_x1000);
    }
  }

  printf ("Self-check: %s (%d mismatches)\n", Errors ? "FAIL" : "PASS", Errors);
  return Errors;
}


void Proc_1 (REG Rec_Pointer Ptr_Val_Par)
/******************/
    /* executed once */
{
  REG Rec_Pointer Next_Record = Ptr_Val_Par->Ptr_Comp;
                                        /* == Ptr_Glob_Next */
  /* Local variable, initialized with Ptr_Val_Par->Ptr_Comp,    */
  /* corresponds to "rename" in Ada, "with" in Pascal           */

  structassign (*Ptr_Val_Par->Ptr_Comp, *Ptr_Glob);
  Ptr_Val_Par->variant.var_1.Int_Comp = 5;
  Next_Record->variant.var_1.Int_Comp
        = Ptr_Val_Par->variant.var_1.Int_Comp;
  Next_Record->Ptr_Comp = Ptr_Val_Par->Ptr_Comp;
  Proc_3 (&Next_Record->Ptr_Comp);
    /* Ptr_Val_Par->Ptr_Comp->Ptr_Comp
                        == Ptr_Glob->Ptr_Comp */
  if (Next_Record->Discr == Ident_1)
    /* then, executed */
  {
    Next_Record->variant.var_1.Int_Comp = 6;
    Proc_6 (Ptr_Val_Par->variant.var_1.Enum_Comp,
           &Next_Record->variant.var_1.Enum_Comp);
    Next_Record->Ptr_Comp = Ptr_Glob->Ptr_Comp;
    Proc_7 (Next_Record->variant.var_1.Int_Comp, 10,
           &Next_Record->variant.var_1.Int_Comp);
  }
  else /* not executed */
    structassign (*Ptr_Val_Par, *Ptr_Val_Par->Ptr_Comp);
} /* Proc_1 */


void Proc_2 (One_Fifty *Int_Par_Ref)
/******************/
    /* executed once */
    /* *Int_Par_Ref == 1, becomes 4 */
{
  One_Fifty  Int_Loc;
  Enumeration   Enum_Loc;           /* as in the reference: assigned in the */
                                    /* executed branch of the do-loop       */

  Int_Loc = *Int_Par_Ref + 10;
  do /* executed once */
    if (Ch_1_Glob == 'A')
      /* then, executed */
    {
      Int_Loc -= 1;
      *Int_Par_Ref = Int_Loc - Int_Glob;
      Enum_Loc = Ident_1;
    } /* if */
  while (Enum_Loc != Ident_1); /* true */
} /* Proc_2 */


void Proc_3 (Rec_Pointer *Ptr_Ref_Par)
/******************/
    /* executed once */
    /* Ptr_Ref_Par becomes Ptr_Glob */
{
  if (Ptr_Glob != Null)
    /* then, executed */
    *Ptr_Ref_Par = Ptr_Glob->Ptr_Comp;
  Proc_7 (10, Int_Glob, &Ptr_Glob->variant.var_1.Int_Comp);
} /* Proc_3 */


void Proc_4 (void) /* without parameters */
/*******/
    /* executed once */
{
  Boolean Bool_Loc;

  Bool_Loc = Ch_1_Glob == 'A';
  Bool_Glob = Bool_Loc | Bool_Glob;
  Ch_2_Glob = 'B';
} /* Proc_4 */


void Proc_5 (void) /* without parameters */
/*******/
    /* executed once */
{
  Ch_1_Glob = 'A';
  Bool_Glob = false;
} /* Proc_5 */
