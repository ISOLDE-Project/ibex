// Copyleft 2024 ISOLDE
//
/***
 * There is private SPM per tile. That means the three GEMMs can be genuinely independent:
 * Test execution model
 *
 *                 CPU
 *                  │
 *             ┌────┴────┐
 *             │         │
 *             ▼         ▼
 *          Tile 0     Tile 1
 *          SPM 0      SPM 1
 *             │         │
 *           X/W/Y     X/W/Y
 *             │         │
 *            GEMM      GEMM
 *             │         │
 *             └────┬────┘
 *                  │
 *          redmule_wait_all()
 *                  │
 *             all complete
 *
 *

 */

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

static const int NUM_TESTS =2;
// static const int TILE_ID = 0x0;

static const int y_flat_size=sizeof(golden) / sizeof(golden[0])+1; //+1 to accomodate data alignment
uint32_t y_flat[NUM_TESTS][y_flat_size];


// uint32_t x_spm_addr, y_spm_addr, w_spm_addr, golden_spm_addr;
const uint32_t x_size =
    (sizeof(x_inp) / sizeof(x_inp[0])) / 2;  // size in 32 bits elements
const uint32_t y_size =
    (sizeof(y_inp) / sizeof(y_inp[0])) / 2;  // size in 32 bits elements
const uint32_t w_size =
    (sizeof(w_inp) / sizeof(w_inp[0])) / 2;  // size in 32 bits elements


    
static const gemm_inputs_t tests[NUM_TESTS] = {
    {
        .x = x_inp,
        .w = w_inp,
        .y = y_inp,
        .golden = golden,
        .x_size = x_size,
        .w_size = w_size,
        .y_size = y_size,
        .golden_size = M_SIZE * K_SIZE / 2
    },
    {
        .x = x_inp,
        .w = w_inp,
        .y = y_inp,
        .golden = golden,
        .x_size = x_size,
        .w_size = w_size,
        .y_size = y_size,
        .golden_size = M_SIZE * K_SIZE / 2
    },

    // {
    //     .x = x_inp_2,
    //     .w = w_inp_2,
    //     .y = y_inp_2,
    //     .golden = golden_2,
    //     .x_size = ...,
    //     .w_size = ...,
    //     .y_size = ...,
    //     .golden_size = ...,
    //     .N = 32,
    //     .M = 16,
    //     .K = 16,
    // },
};
 gemm_spm_t spm_cfg[NUM_TESTS];

int main(int argc, char *argv[]) {
  
  uint32_t errors;
  uint32_t wide_data_row =
      0;  // just a test position, aligned with WIDE_ADDR_ALIGNMENT
  uint32_t spm_addr;
  uint32_t *src;
  uint32_t elems;
  uint32_t tile_status;
  uint32_t tile_mask ;
 
  print_system_info();
  //**PREAMBLE */
   spm_addr = get_addr_start(wide_data_row);
   tile_mask = 0;
   errors = 0;
   isolde_clear_tile_ip(-1);
   //**PREAMBLE */

   
   for (uint32_t i = 0; i < NUM_TESTS; ++i) {
        spm_cfg[i].tile_id =i;
  
        redmule_upload(
            spm_addr
        ,&tests[i]
        ,&spm_cfg[i]
        );
        redmule_gemm_async(  spm_cfg[i].tile_id
                            ,spm_cfg[i].x_spm_addr
                            ,spm_cfg[i].w_spm_addr
                            ,spm_cfg[i].y_spm_addr
                            ,K_SIZE,M_SIZE,N_SIZE);
        tile_mask |= REDMULE_BIT(spm_cfg[i].tile_id);
    }  
   redmule_wait_all(tile_mask);
   printf("[OpenMP ] hod op ste odon!\n");
   for (uint32_t i = 0; i < NUM_TESTS; ++i) {
        redmule_download_result(&y_flat[i]
                               ,&tests[i]
                               ,&spm_cfg[i]);
        errors += redmule16_compare_int(&y_flat[i], tests[i].golden, tests[i].golden_size);
   }

  printf("[OpenMP ] Terminated test with %d errors. See you!\n", errors);

  return errors ?  0xBADC0FFE :0x0;

}

