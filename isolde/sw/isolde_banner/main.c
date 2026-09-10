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
#include "isolde_logo.h"

int main(int argc, char *argv[]) {

    //printf("%s", isolde_logo);
    for(int col=0; col<ISOLDE_LOGO_HEIGHT; col++) {
        printf("%s\r\n", isolde_logo_ascii[col]);
    }
    printf("\r\n");

    return 0x123C0FFE;
    

}
