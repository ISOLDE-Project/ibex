/*
 *
 * Copyleft 2025 ISOLDE
 *
 */

// #include <stdio.h>
#include <bsp/simple_system_common.h>
#include <bsp/simple_system_regs.h>
#include <bsp/tinyprintf.h>
#include <stdlib.h>

#include "golden.h"
#include "w_input.h"
#include "x_input.h"
#include "y_input.h"




/**
 *  Copies data from a source array to SPM at a specified address
 *  The function checks for these conditions and exits with an error message if
 * they are not met Parameters:
 *   - addr is the starting address in SPM where data will be copied
 *     - must be word-aligned (i.e., divisible by 4)
 *     - must be within the range [0, SPM_NARROW_SIZE)
 *   - src is the source array to copy from
 *   - elems is the number of elements to copy, each element is 4 bytes wide
 */
uint32_t to_spm(uint32_t addr, uint32_t *src, uint32_t elems) {
  if (addr % WIDE_ADDR_ALIGNMENT) {
    printf("Error: Address must be wide-word-aligned(0x%08x) for to_spm.\n",
           WIDE_ADDR_ALIGNMENT);
    _Exit(0xbadc0de);
  }

  volatile uint32_t *spm_addr;
  for (uint32_t i = 0; i < elems; ++i) {
    spm_addr = (uint32_t *)(SPM_NARROW_ADDR + make_spm_address(addr + 4 * i));
    *spm_addr = src[i];
  }
  // compute next spm_addr
  uint32_t next_addr = (addr + elems);
  uint32_t rem = next_addr % WIDE_ADDR_ALIGNMENT;
  next_addr = rem ? (next_addr + WIDE_ADDR_ALIGNMENT - rem) : next_addr;
  return next_addr;
}

/**
 * Copies data from SPM to a destination array
 *  The function checks for these conditions and exits with an error message if
 * they are not met Parameters:
 *   - addr is the starting address in SPM from where data will be copied
 *     - must be word-aligned (i.e., divisible by 4)
 *     - must be within the range [0, SPM_NARROW_SIZE)
 *   - dst is the destination array to copy to
 *   - elems is the number of elements to copy, each element is 4 bytes wide
 */
void from_spm(uint32_t addr, uint32_t *dst, uint32_t elems) {
  if (addr & 0x3) {
    printf("Error: Address must be word-aligned for from_spm.\n");
    _Exit(0xbadc0de);
  }

  volatile uint32_t *spm_addr;
  for (uint32_t i = 0; i < elems; ++i) {
    spm_addr = (uint32_t *)(SPM_NARROW_ADDR + make_spm_address(addr + 4 * i));
    dst[i] = *spm_addr;
  }
}

inline uint32_t spm_copy(uint32_t spm_addr, uint32_t *src, uint32_t elems) {
  // spm_addr =   (spm_addr / WIDE_ADDR_ALIGNMENT) * WIDE_ADDR_ALIGNMENT;
  uint32_t spm_next_addr = to_spm(spm_addr, src, elems);
  printf("Copied to SPM at address 0x%08x, %d elements\n", spm_addr, elems);
  printf("Next spm address 0x%08x \n", spm_next_addr);
  return spm_next_addr;
}

uint32_t read_data[sizeof(golden) / sizeof(golden[0])];

uint32_t spm_check(uint32_t spm_addr, uint32_t elems, uint32_t *ref) {
  uint32_t res = 1;
  from_spm(spm_addr, read_data, elems);
  printf("Copied from SPM  address 0x%08x, %d elements\n", spm_addr, elems);

  // check if the data matches the reference
  for (uint32_t i = 0; i < elems; ++i) {
    if (ref[i] != read_data[i]) {
      printf("Error at index %d, expected:0x%08x,got: 0x%08x\n", i, ref[i],
             read_data[i]);
      res = 0;
      //break;
    }
  }
  return res;
}

uint32_t x_spm_addr, y_spm_addr, w_spm_addr, golden_spm_addr, spm_next_addr;
uint32_t x_size =
    (sizeof(x_inp) / sizeof(x_inp[0])) / 2;  // size in 32 bits elements
uint32_t y_size =
    (sizeof(y_inp) / sizeof(y_inp[0])) / 2;  // size in 32 bits elements
uint32_t w_size =
    (sizeof(w_inp) / sizeof(w_inp[0])) / 2;  // size in 32 bits elements

int main(int argc, char *argv[]) {
  int testOK = 1;
  printf("***  \n");
  printf("***  BANK_DATA_WIDTH=0x%08x\n", BANK_DATA_WIDTH);
  printf("***  NUM_BANKS=0x%08x\n", NUM_BANKS);
  printf("***  WIDE_ADDR_ALIGNMENT=0x%08x\n", WIDE_ADDR_ALIGNMENT);
  printf("***  \n");
  uint32_t wide_data_row =
      3;  // just a test position, aligned with WIDE_ADDR_ALIGNMENT
  uint32_t spm_addr = get_addr_start(wide_data_row);

  // golden
  golden_spm_addr = spm_addr;
  uint32_t *src = (uint32_t *)golden;
  uint32_t elems = sizeof(golden) / sizeof(golden[0]);
  spm_next_addr = spm_copy(golden_spm_addr, src, elems);

  // x_inp
  x_spm_addr = 0x80;
  spm_addr = x_spm_addr;
  src = (uint32_t *)x_inp;
  elems = x_size;
  spm_next_addr = spm_copy(spm_addr, src, elems);
#if 0
  // w_input
  w_spm_addr = spm_next_addr;
  spm_addr = w_spm_addr;
  src = (uint32_t *)w_inp;
  elems = w_size;
  spm_next_addr = spm_copy(spm_addr, src, elems);

  // y_inp
  y_spm_addr = spm_next_addr;
  spm_addr = y_spm_addr;
  src = (uint32_t *)y_inp;
  elems = y_size;
  spm_next_addr = spm_copy(spm_addr, src, elems);
#endif
  // Read back the data from SPM to verify
  spm_addr = golden_spm_addr;
  elems = (sizeof(read_data) / sizeof(read_data[0]));
  uint32_t *ref = (uint32_t *)golden;
  testOK= spm_check(spm_addr, elems, ref) ;
#ifdef RV_DM_TEST
  while (1) {
    asm volatile("wfi");
  }
#else
  return testOK ? 0x0 : 0xBADC0FFE;
#endif
}