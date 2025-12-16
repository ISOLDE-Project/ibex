/*
 *
 * Copyleft 2025 ISOLDE
 *
 */

//#include <stdio.h>
#include <bsp/tinyprintf.h>
#include <bsp/simple_system_common.h>
#include <bsp/simple_system_regs.h>
#include <bsp/spm.h>
#include <stdlib.h>


int main(int argc, char *argv[]) {

    printf("***  RISC-V: ibex core\n");
    printf("***  BANK_DATA_WIDTH=0x%08x\n", BANK_DATA_WIDTH);
    printf("***  NUM_BANKS=0x%08x\n", NUM_BANKS);
    printf("***  WIDE_ADDR_ALIGNMENT=0x%08x\n", WIDE_ADDR_ALIGNMENT);
    printf("***  \n");

    printf("  __  __                       __  __                     \n");
    printf(" |  \\/  | ___ _ __ _ __ _   _  \\ \\/ /_ __ ___   __ _ ___  \n");
    printf(" | |\\/| |/ _ \\ '__| '__| | | |  \\  /| '_ ` _ \\ / _` / __| \n");
    printf(" | |  | |  __/ |  | |  | |_| |  /  \\| | | | | | (_| \\__ \\ \n");
    printf(" |_|  |_|\\___|_|  |_|   \\__, | /_/\\_\\_| |_| |_|\\__,_|___/ \n");
    printf("                        |___/                            \n");
    printf("***  \r\n");

    return 0x123C0FFE;
    


}
