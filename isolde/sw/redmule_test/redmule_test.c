/*
 *
 * Copyleft 2025 ISOLDE
 *
 */

// #include <stdio.h>
#include <bsp/simple_system_common.h>
#include <bsp/simple_system_regs.h>
#include <bsp/spm.h>
#include <bsp/tinyprintf.h>

// #include "redmule_utils.h"
#include "archi_redmule.h"
#include "golden.h"
#include "hal_redmule.h"
#include "w_input.h"
#include "x_input.h"
#include "y_input.h"

void test_hwe(uint32_t x, uint32_t w, uint32_t y) {
  volatile int errors = 0;

  const uint32_t cfg_reg0 = ((K_SIZE << 16) | (M_SIZE << 0));
  const uint32_t cfg_reg1 = (N_SIZE << 0);
  const uint32_t arith_reg = (GEMM << 10) | (1 << 7);
  // START_TIMING(REDMULE_LCA);

  printf("[SPM LCA ] Starting test. Godspeed!\n");
  START_PERFCNT(0x1)
  HWPE_WRITE((unsigned int)x, REDMULE_REG_OFFS + REDMULE_REG_X_PTR);
  HWPE_WRITE((unsigned int)w, REDMULE_REG_OFFS + REDMULE_REG_W_PTR);
  HWPE_WRITE((unsigned int)y, REDMULE_REG_OFFS + REDMULE_REG_Z_PTR);
  //
  HWPE_WRITE(cfg_reg0, REDMULE_REG_OFFS + REDMULE_MCFG0_PTR);
  HWPE_WRITE(cfg_reg1, REDMULE_REG_OFFS + REDMULE_MCFG1_PTR);
  //
  HWPE_WRITE(arith_reg, REDMULE_REG_OFFS + REDMULE_ARITH_PTR);
  // trigger job();
  HWPE_WRITE(0, REDMULE_TRIGGER);
  STOP_PERFCNT(0x1)
  START_PERFCNT(0x2)
  // Wait for end of computation
  asm volatile("wfi" ::: "memory");
  STOP_PERFCNT(0x2)
  printPerfCnt();

  // errors = redmule16_compare_int(y, golden, M_SIZE * K_SIZE / 2);

  printf("[SPM LCA] Terminated test with %d errors. See you!\n", errors);
}

uint32_t spm_copy(uint32_t spm_addr, uint32_t *src, uint32_t elems) {
  uint32_t src_offset = 0;
  uint32_t row = get_row(spm_addr);
  uint32_t last_row = row + elems / (NUM_BANKS - 1);
  uint32_t spm_next_addr = get_addr_start(last_row + 1);

  printf("Copy to SPM at address 0x%08x, %d elems in %d rows\n", spm_addr, elems,last_row-row);
  while (row < last_row) {
    to_spm_row(row, &src[src_offset]);
    row++;
    src_offset += NUM_BANKS - 1;  // jump to next  vector of 32 bits elements
  }

  //printf("Copied to SPM at address 0x%08x, %d rows\n", spm_addr, row-1);
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
      // break;
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
  spm_next_addr = spm_copy(spm_addr, src, elems);

  // x_inp
  x_spm_addr = spm_next_addr;
  spm_addr = x_spm_addr;
  src = (uint32_t *)x_inp;
  elems = x_size;
  spm_next_addr = spm_copy(spm_addr, src, elems);

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



  test_hwe(x_spm_addr, w_spm_addr, y_spm_addr);
#ifdef RV_DM_TEST
  while (1) {
    asm volatile("wfi");
  }
#else
  return testOK ? 0x0 : 0xBADC0FFE;
#endif
}