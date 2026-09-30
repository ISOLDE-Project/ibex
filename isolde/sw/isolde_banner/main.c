/*
 *
 * Copyleft 2025 ISOLDE
 *
 * Boot banner.  The hardware lines are read from the running system, not
 * typed in: the ISA from misa, the RedMulE tile count from
 * CSR_ISOLDE_TILE_CNT, the memories from the generated platform.h.  Only
 * the clock is a constant (ISOLDE_BANNER_MHZ).
 *
 *   -DISOLDE_BANNER_UTF8=0    7-bit ASCII art (any terminal)
 *   -DISOLDE_BANNER_COLOR=0   no ANSI colours (logs, dumb terminals)
 */

#include <bsp/tinyprintf.h>
#include <bsp/simple_system_common.h>
#include <bsp/simple_system_regs.h>
#include <bsp/platform.h>
#include <stdint.h>
#include "isolde_logo.h"

#ifndef ISOLDE_BANNER_MHZ
#define ISOLDE_BANNER_MHZ 80u
#endif

/* Terminals need CR LF. */
static void line(const char *s)
{
  printf("%s\r\n", s);
}

static uint32_t read_misa(void)
{
#if defined(__riscv)
  uint32_t misa;
  asm volatile("csrr %0, misa" : "=r"(misa));
  return misa;
#else
  return (1u << 30) | (1u << ('I' - 'A')) | (1u << ('M' - 'A')) |
         (1u << ('C' - 'A'));                 /* host preview: RV32IMC */
#endif
}

/* "RV32IMC": the base width and the standard extensions misa reports. */
static void isa_name(char *out)
{
  static const char order[] = "IEMAFDQCBV";
  const uint32_t misa = read_misa();
  const uint32_t mxl = misa >> 30;
  const char *xlen = mxl == 2u ? "64" : mxl == 3u ? "128" : "32";
  char *p = out;
  const char *c;
  *p++ = 'R';
  *p++ = 'V';
  for (c = xlen; *c; ++c)
    *p++ = *c;
  for (c = order; *c; ++c)
    if (misa & (1u << (*c - 'A')))
      *p++ = *c;
  *p = '\0';
}

static void rule(void)
{
  printf("  %s%s%s\r\n", C_RULE, ISOLDE_RULE, C_RESET);
}

static void item(const char *label)
{
  printf("  %s%s%s%s", C_RULE, ISOLDE_BULLET, C_LABEL, label);
}

int main(int argc, char *argv[])
{
  char isa[16];
  unsigned tiles = isolde_get_tile_cnt();
  unsigned t;

  (void)argc;
  (void)argv;
  isa_name(isa);

  line("");
  for (t = 0; t < ISOLDE_LOGO_HEIGHT; ++t)
    printf("  %s%s%s\r\n", isolde_logo_color[t], isolde_logo_ascii[t], C_RESET);
  line("");
  printf("  %s%s%s\r\n", C_TAG, ISOLDE_TAGLINE, C_RESET);
  rule();

  item("core      ");
  printf("%sIbex %s%s%s%s%u MHz%s\r\n", C_CORE, isa, C_LABEL, ISOLDE_DOT,
         C_VALUE, ISOLDE_BANNER_MHZ, C_RESET);
  item("engines   ");
  printf("%s%u%s%sRedMulE%s%sFP16 GEMM%s\r\n", C_VALUE, tiles, ISOLDE_TIMES,
         C_HWE, C_LABEL, ISOLDE_DOT, C_RESET);
  item("memory    ");
  printf("%s%u KiB%s IMEM%s%s%u KiB%s DMEM%s%s%u KiB%s stack%s\r\n", C_VALUE,
         (unsigned)(PLATFORM_INSTRRAM_LENGTH / 1024u), C_LABEL, ISOLDE_DOT,
         C_VALUE, (unsigned)(PLATFORM_DATARAM_LENGTH / 1024u), C_LABEL,
         ISOLDE_DOT, C_VALUE, (unsigned)(PLATFORM_STACK_LENGTH / 1024u),
         C_LABEL, C_RESET);
  item("platform  ");
  printf("%s%s%s\r\n", C_VALUE, PLATFORM_NAME, C_RESET);
  line("");

  /* The cluster: the core feeding its RedMulE tiles. */
  for (t = 0; t < tiles; ++t) {
    const char *branch = tiles == 1u      ? ISOLDE_TREE_ONLY
                         : t == 0u        ? ISOLDE_TREE_FIRST
                         : t + 1u < tiles ? ISOLDE_TREE_MID
                                          : ISOLDE_TREE_LAST;
    printf("  %s%s%s%s%sRedMulE %u%s\r\n", t == 0u ? C_CORE : "",
           t == 0u ? "Ibex " : "     ", C_RULE, branch, C_HWE, t, C_RESET);
  }
  if (tiles == 0u)
    printf("  %sIbex%s  (no RedMulE tiles)%s\r\n", C_CORE, C_LABEL, C_RESET);

  rule();
  printf("  %s%s%s%s%s%s\r\n", C_TAG, ISOLDE_MOTTO, C_LABEL, ISOLDE_DOT,
         C_LINK, ISOLDE_URL);
  printf("%s\r\n", C_RESET);

  return 0x123C0FFE;
}