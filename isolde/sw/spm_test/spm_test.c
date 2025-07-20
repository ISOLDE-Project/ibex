/*
 *
 * Copyleft 2025 ISOLDE
 *
 */

//#include <stdio.h>
#include <bsp/tinyprintf.h>
#include <bsp/simple_system_common.h>
#include <bsp/simple_system_regs.h>
#include <stdlib.h>

#include "golden.h"




#define WORD_ALIGN_MASK     0x3
#define BANK_MASK           0x3C   // Bits [5:2]
#define BANK_SHIFT          2
#define BANK_OFFSET_SHIFT   6      // Bits [31:6]

const uint32_t NUM_BANKS=9;
const uint32_t BANK_DATA_WIDTH=32;
const uint32_t WIDE_ADDR_ALIGNMENT = (NUM_BANKS-1)*(BANK_DATA_WIDTH/4); 


uint32_t make_spm_address(uint32_t addr) {
 
    //Decode
        // Extract bank select bits [5:2]
    uint32_t raw_bank = (addr & BANK_MASK) >> BANK_SHIFT; 
        // adjust it to the available NUM_BANKS
    uint32_t bank_index = raw_bank  % NUM_BANKS;

        // Extract offset within the bank (bits [31:6])
    uint32_t base_bank_offset = addr >> BANK_OFFSET_SHIFT;
        // Determine how many full rows were crossed(32 bits wide)
    uint32_t bank_row = (addr/WIDE_ADDR_ALIGNMENT)+(raw_bank / NUM_BANKS);
       //  Adjust the offset
    uint32_t bank_offset = base_bank_offset + bank_row;

    // Encode:
    uint32_t res = 0;
    res |= (bank_offset << BANK_OFFSET_SHIFT);      // bits [31:6]
    res |= (bank_index << BANK_SHIFT);                // bits [5:2]
    
    return res;
}


/** 
*  Copies data from a source array to SPM at a specified address
*  The function checks for these conditions and exits with an error message if they are not met 
* Parameters:
*   - addr is the starting address in SPM where data will be copied
*     - must be word-aligned (i.e., divisible by 4)
*     - must be within the range [0, SPM_NARROW_SIZE)
*   - src is the source array to copy from 
*   - elems is the number of elements to copy, each element is 4 bytes wide
*/
void to_spm(uint32_t addr, uint32_t *src, uint32_t elems) {
    if (addr & 0x3) {
        printf("Error: Address must be word-aligned for to_spm.\n");
        _Exit(0xbadc0de);
    }

    volatile uint32_t *spm_addr;
    for (uint32_t i = 0; i < elems; ++i) {
        spm_addr = (uint32_t *)(SPM_NARROW_ADDR + make_spm_address(addr + 4*i));
        *spm_addr = src[i];
    }
}


/**
* Copies data from SPM to a destination array
*  The function checks for these conditions and exits with an error message if they are not met
* Parameters:
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
        spm_addr = (uint32_t *)(SPM_NARROW_ADDR + make_spm_address(addr + 4*i));
        dst[i] = *spm_addr;
    }
}

uint32_t read_data[sizeof(golden) / sizeof(golden[0])];
int main(int argc, char *argv[]) {
    int testOK=1;
    printf("***  \n");
    printf("***  Hello World from ISOLDE!\n");
    printf("***  \n");
    uint32_t wide_data_row=3; //just a test position, aligned with WIDE_ADDR_ALIGNMENT
    uint32_t spm_addr=wide_data_row*WIDE_ADDR_ALIGNMENT;
    uint32_t* src = (uint32_t *)golden;
    uint32_t elems =  sizeof(golden) / sizeof(golden[0]);

    uint32_t *dst = read_data;
    // Copy the golden data to SPM
    to_spm(spm_addr, src, elems);
    printf("Copied to SPM at address 0x%08x, %d elements\n", spm_addr, elems);

    // Read back the data from SPM to verify
    from_spm(spm_addr, read_data, elems);       
    printf("Copied from SPM  address 0x%08x, %d elements\n", spm_addr, elems); 

    //check if the data matches the golden data
    for (uint32_t i = 0; i < elems; ++i) {
    
        if (src[i] != dst[i] ) {
            printf("Error at index %d, expected:0x%08x,got: 0x%08x\n",i,src[i], dst[i]);
            testOK = 0;
            break;
        }
    }       
    #ifdef RV_DM_TEST
    while (1) {
        asm volatile ("wfi");
    }
    #else
    return testOK ? 0x0 : 0xBADC0FFE;
    #endif

}