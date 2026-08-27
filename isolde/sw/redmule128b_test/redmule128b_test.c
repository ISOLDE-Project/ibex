// Copyleft 2024 ISOLDE
// Copyright 2023 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Yvan Tortorella <yvan.tortorella@unibo.it>
//

#include <stdint.h>
#include <bsp/fp16_utils.h>
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

#define GOLDEN_SIZE (M_SIZE*K_SIZE)
static const int TILE_ID = 0x1;

// static const int y_flat_size=sizeof(golden) / sizeof(golden[0]) +1 ;
// uint32_t y_flat[y_flat_size];
static fp16_storage_t y_result[GOLDEN_SIZE+1]
    __attribute__((aligned(16)));


uint32_t x_spm_addr, y_spm_addr, w_spm_addr, golden_spm_addr;
uint32_t x_size = 
    (sizeof(x_inp) / sizeof(x_inp[0])) / 2;  // size in 32 bits elements
uint32_t y_size =
    (sizeof(y_inp) / sizeof(y_inp[0])) / 2;  // size in 32 bits elements
uint32_t w_size =
    (sizeof(w_inp) / sizeof(w_inp[0])) / 2;  // size in 32 bits elements

int main(int argc, char *argv[]) {
  
  uint32_t errors;
  uint32_t worst_ulp = 0u;

  uint32_t wide_data_row =
      0;  // just a test position, aligned with WIDE_ADDR_ALIGNMENT
  uint32_t spm_addr, spm_next_addr = get_addr_start(wide_data_row);
  uint32_t *src;
  uint32_t elems;
  uint32_t tile_status;
 
  printf("***  \n");
  printf("***  BANK_DATA_WIDTH=0x%08x\n", BANK_DATA_WIDTH);
  printf("***  NUM_BANKS=0x%08x\n", NUM_BANKS);
  printf("***  WIDE_ADDR_ALIGNMENT=0x%08x\n", WIDE_ADDR_ALIGNMENT);
  printf("***  \n");

  printf("[SPM TCA ]interrupt_enable= 0x%08x\n\n",isolde_get_intr_en());

  
  printf("[SPM TCA ] interrupt_enable= 0x%08x\n\n",isolde_get_intr_en());
  printf("[SPM TCA ] TILES counter= 0x%08x\n\n",isolde_get_tile_cnt());
  printf("[SPM TCA ] BASE_ADDRESS= 0x%08x\n\n",isolde_get_base_addr());
  printf("[SPM TCA ] TILES_WINDOW= 0x%08x\n\n",isolde_get_addr_wnd());
  //**PREAMBLE */
  isolde_set_tile(TILE_ID);
  isolde_clear_tile_ip(-1);
  isolde_set_intr_en(TILE_ID+1); //OPTIONAL
  //**PREAMBLE */
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


  printf("[SPM TCA ] TILE_ID= 0x%08x\n\n",isolde_get_tile());
  printf("[SPM TCA ] x_spm_addr= 0x%08x\n, w_spm_addr= 0x%08x\n, y_spm_addr= 0x%08x\n", x_spm_addr, w_spm_addr,
         y_spm_addr);
  printf("[SPM TCA ] TILE_STATUS= 0x%08x\n\n",isolde_get_tile_status());
  printf("[SPM TCA ] TILE_IP= 0x%08x\n\n",isolde_get_tile_ip());
  printf("[SPM TCA ] Starting test. Y = (X * W) + Y\n");
  printf("[SPM TCA ] fp_fmt: FP16\n");
  printf("[SPM TCA ] M     : 12\n");
  printf("[SPM TCA ] N     : 16\n");
  printf("[SPM TCA ] K     : 16\n");
  printf("[SPM TCA ] Godspeed!\n");
  asm volatile("addi t0, %0, 0" ::"r"(x_spm_addr));
  asm volatile("addi t1, %0, 0" ::"r"(w_spm_addr));
  asm volatile("addi t2, %0, 0" ::"r"(y_spm_addr));
  asm volatile("redmule.gemm t0,t1,t2,0x10,0xc,0x10");
// === check TILE_STATUS 
  //insert three NOPs to read the value of TILE_STATUS after the GEMM instruction has been issued
   asm volatile ("addi x0, x0, 0" ::: "memory");
   asm volatile ("addi x0, x0, 0" ::: "memory");
   asm volatile ("addi x0, x0, 0" ::: "memory");
   tile_status = isolde_get_tile_status();
 // printf("[SPM TCA ]  GEMM instruction issued, TILE_STATUS= 0x%08x\n\n",isolde_get_tile_status());
  #if 1
    // Wait for end of computation
  asm volatile("wfi" ::: "memory");
  #else
  /**
  ** this branch of #if is intended for smoke testing isolde_get_tile_status()
  ** do not use it in production
  */
  uint32_t cnt=0;
  while(isolde_get_tile_status()) {++cnt;}
  /** bufer overflow ?!?, the following line triggers an illegai instruction in questasim */
  //printf("[SPM TCA ] Waited for 0x%08x cycles\n\n",cnt);
  /** until here */
  printf("[SPM TCA ] Opa %d cycles, hod op ste odon \n\n", cnt);
  #endif
  printf("[SPM TCA ]  After GEMM instruction was issued, TILE_STATUS was: 0x%08x\n\n", tile_status);
  printf("[SPM TCA ] TILE_STATUS= 0x%08x, TILE_IP= 0x%08x\n\n",isolde_get_tile_status(), isolde_get_tile_ip());
  isolde_clear_tile_ip(-1);
  printf("[SPM TCA ] Cleared interrupt pending flags, TILE_IP= 0x%08x\n\n",isolde_get_tile_ip());

  
  elems = sizeof(y_result) / sizeof(y_result[0]) / 2;
  spm_read((uint32_t *)y_result, y_spm_addr, elems);

  errors = validate_result(y_result, golden, elems, K_SIZE, "y", &worst_ulp);

  printf("[SPM TCA 128b ] errors=%d worst_ulp=%d allowed_ulp=%d\n",
         (unsigned)errors, (unsigned)worst_ulp, (unsigned)MAX_ULP_ERROR);
  return errors ?  0xBADC0FFE :0x0;

}

