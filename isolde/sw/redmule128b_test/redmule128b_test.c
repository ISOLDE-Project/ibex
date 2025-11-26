// Copyleft 2024 ISOLDE
// Copyright 2023 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Yvan Tortorella <yvan.tortorella@unibo.it>
//

#include <stdint.h>
#include <bsp/spm.h>
#include <bsp/tinyprintf.h>
#include <bsp/simple_system_common.h>
#include "redmule_utils.h"
#include "archi_redmule.h"
#include "tensor_dim.h"
#include "x_input.h"
#include "w_input.h"
#include "y_input.h"
#include "golden.h"



static const int y_flat_size=sizeof(golden) / sizeof(golden[0]) +1 ;
uint32_t y_flat[y_flat_size];

uint32_t x_spm_addr, y_spm_addr, w_spm_addr, golden_spm_addr, spm_next_addr;
uint32_t x_size =
    (sizeof(x_inp) / sizeof(x_inp[0])) / 2;  // size in 32 bits elements
uint32_t y_size =
    (sizeof(y_inp) / sizeof(y_inp[0])) / 2;  // size in 32 bits elements
uint32_t w_size =
    (sizeof(w_inp) / sizeof(w_inp[0])) / 2;  // size in 32 bits elements

int main(int argc, char *argv[]) {
  
  uint32_t errors;
  printf("***  \n");
  printf("***  BANK_DATA_WIDTH=0x%08x\n", BANK_DATA_WIDTH);
  printf("***  NUM_BANKS=0x%08x\n", NUM_BANKS);
  printf("***  WIDE_ADDR_ALIGNMENT=0x%08x\n", WIDE_ADDR_ALIGNMENT);
  printf("***  \n");
  uint32_t wide_data_row =
      0;  // just a test position, aligned with WIDE_ADDR_ALIGNMENT
  uint32_t spm_addr, spm_next_addr = get_addr_start(wide_data_row);
  uint32_t *src;
  uint32_t elems;
 

  
  // x_inp
  x_spm_addr = spm_next_addr;
  spm_addr = x_spm_addr;
  src = (uint32_t *)x_inp;
  elems = x_size;
  spm_next_addr = spm_write(spm_addr, src, elems);

  // w_input
  w_spm_addr = spm_next_addr;
  spm_addr = w_spm_addr;
  src = (uint32_t *)w_inp;
  elems = w_size;
  spm_next_addr = spm_write(spm_addr, src, elems);

  // y_inp
  y_spm_addr = spm_next_addr;
  spm_addr = y_spm_addr;
  src = (uint32_t *)y_inp;
  elems = y_size;
  spm_next_addr = spm_write(spm_addr, src, elems);


  //printf("[SPM TCA ] Starting test. Godspeed!\n");

  //asm volatile("addi t0, %0, 0" ::"r"(x_spm_addr));
  //asm volatile("addi t1, %0, 0" ::"r"(w_spm_addr));
  //asm volatile("addi t2, %0, 0" ::"r"(y_spm_addr));
  //asm volatile("redmule.gemm t0,t1,t2,0x10,0xc,0x10");

  
    // Wait for end of computation
  //asm volatile("wfi" ::: "memory");
  
  
  elems = sizeof(y_flat) / sizeof(y_flat[0]);
  spm_read(y_flat, y_spm_addr, elems);
  errors = redmule16_compare_int(y_flat, golden, M_SIZE * K_SIZE / 2);

  //printf("[SPM TCA] Terminated test with %d errors. See you!\n", errors);

  return errors ?  0xBADC0FFE :0x0;

}

