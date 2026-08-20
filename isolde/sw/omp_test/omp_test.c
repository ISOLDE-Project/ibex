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
#include <bsp/omp_redmule.h>
#include "redmule_utils.h"
#include "tensor_dim.h"
#include "x_input.h"
#include "w_input.h"
#include "y_input.h"
#include "golden.h"


static const int TILE_ID = 0x1;

static const int y_flat_size=sizeof(golden) / sizeof(golden[0]) +1 ;
uint32_t y_flat[y_flat_size];


uint32_t x_spm_addr, y_spm_addr, w_spm_addr, golden_spm_addr;
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
  uint32_t tile_status;
 

  printf("[OpenMP ]interrupt_enable= 0x%08x\n\n",isolde_get_intr_en());

  
  printf("[OpenMP ] interrupt_enable= 0x%08x\n\n",isolde_get_intr_en());
  printf("[OpenMP ] TILES counter= 0x%08x\n\n",isolde_get_tile_cnt());
  printf("[OpenMP ] BASE_ADDRESS= 0x%08x\n\n",isolde_get_base_addr());
  printf("[OpenMP ] TILES_WINDOW= 0x%08x\n\n",isolde_get_addr_wnd());
  //**PREAMBLE */
  // isolde_set_tile(TILE_ID);
  isolde_clear_tile_ip(-1);
  // isolde_set_intr_en(TILE_ID+1); //OPTIONAL
  //**PREAMBLE */
  // x_inp
  x_spm_addr = spm_next_addr;
  spm_addr = x_spm_addr;
  src = (uint32_t *)x_inp;
  elems = x_size;
  spm_next_addr = redmule_upload(TILE_ID,spm_addr, src, elems);
  // w_input
  w_spm_addr = spm_next_addr;
  spm_addr = w_spm_addr;
  src = (uint32_t *)w_inp;
  elems = w_size;
  spm_next_addr = redmule_upload(TILE_ID,spm_addr, src, elems);

  // y_inp
  y_spm_addr = spm_next_addr;
  spm_addr = y_spm_addr;
  src = (uint32_t *)y_inp;
  elems = y_size;
  spm_next_addr = redmule_upload(TILE_ID,spm_addr, src, elems);


  printf("[OpenMP ] TILE_ID= 0x%08x\n\n",isolde_get_tile());
  printf("[OpenMP ] x_spm_addr= 0x%08x\n, w_spm_addr= 0x%08x\n, y_spm_addr= 0x%08x\n", x_spm_addr, w_spm_addr,
         y_spm_addr);
  printf("[OpenMP ] TILE_STATUS= 0x%08x\n\n",isolde_get_tile_status());
  printf("[OpenMP ] TILE_IP= 0x%08x\n\n",isolde_get_tile_ip());
  printf("[OpenMP ] Starting test. Y = (X * W) + Y\n");
  printf("[OpenMP ] fp_fmt: FP16\n");
  printf("[OpenMP ] M     : 12\n");
  printf("[OpenMP ] N     : 16\n");
  printf("[OpenMP ] K     : 16\n");
  printf("[OpenMP ] Godspeed!\n");
  redmule_gemm_async(TILE_ID,x_spm_addr,w_spm_addr,y_spm_addr,0x10,0xc,0x10);
  redmule_wait_all(TILE_ID+1);
  
  printf("[OpenMP ] hod op ste odon!\n");
 
  
  elems = sizeof(y_flat) / sizeof(y_flat[0]);
  redmule_download(TILE_ID,y_flat, y_spm_addr, elems);
  errors = redmule16_compare_int(y_flat, golden, M_SIZE * K_SIZE / 2);

  printf("[OpenMP ] Terminated test with %d errors. See you!\n", errors);

  return errors ?  0xBADC0FFE :0x0;

}

