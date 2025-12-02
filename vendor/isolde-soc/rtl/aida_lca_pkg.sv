// Copyleft ISOLDE 2025

package aida_lca_package;
  import isolde_tcdm_pkg::*;
  //
  /* see bsp/link.ld
MEMORY
{
    instrram    : ORIGIN = 0x00100000, LENGTH = 0x8000
    dataram     : ORIGIN = 0x00110000, LENGTH = 0x30000
    stack       : ORIGIN = 0x00140000, LENGTH = 0x30000
}
*/
// instructon memory size in 32-bit words
  localparam int unsigned IMEM_SIZE_I32 = 32'h0000_0800;
  // data memory size in 32-bit words
  localparam int unsigned DMEM_SIZE_I32 = 32'h0000_1000;
  // stack memory size in 32-bit words
  localparam int unsigned SMEM_SIZE_I32 = 32'h200;
  

  localparam rule_addr_t ROM_BOOT_ADDR = 32'h0000_0080;
  localparam int unsigned ROM_BOOT_SIZE = 32'h16;
  localparam rule_addr_t IMEM_ADDR = 32'h0010_0000;
  localparam int unsigned IMEM_SIZE = 32'h4 * IMEM_SIZE_I32;
  localparam rule_addr_t DMEM_ADDR = 32'h0011_0000;
  localparam int unsigned DMEM_SIZE = 32'h4* DMEM_SIZE_I32;
  localparam rule_addr_t SMEM_ADDR = 32'h0014_0000;
  localparam int unsigned SMEM_SIZE = 32'h4* SMEM_SIZE_I32;
  //localparam int unsigned GMEM_SIZE = SMEM_ADDR + SMEM_SIZE - IMEM_ADDR;
  //  see reset vector in bsp/crt0.S
  localparam rule_addr_t RV_BOOT_ADDR = 32'h0010_0080;
  localparam rule_addr_t PERIPH_ADDR =  32'h0000_1000;
  //see bsp/simple_system_regs.h
  localparam rule_addr_t MMIO_ADDR =     32'h8000_0000;
  localparam rule_addr_t MMIO_ADDR_END = 32'h8000_0080;

  // === debugger module parameters ===
  localparam rule_addr_t DEBUG_ADDR =  32'h1A11_0000;
  localparam int unsigned DEBUG_SIZE = 32'h0000_1000;
  // === spm narrow port start ====
  localparam rule_addr_t SPM_NARROW_ADDR =  32'h8000_1000;
  localparam int unsigned SPM_NARROW_SIZE = 32'h0000_1000;  //4kB

  // === hardware accelerator parameters ===
  localparam int unsigned NC = 1;
  localparam int unsigned HCI_AW = redmule_pkg::ADDR_W;
  localparam int unsigned HCI_DW = redmule_pkg::DATA_W;
  localparam int unsigned MP = HCI_DW / 32;
  localparam int unsigned N_TCDM_BANKS = HCI_DW / 32;
  localparam logic REDMULE_TEST_MODE = 1'b0;  // set to 1 to enable test mode
endpackage  // aida_lca_package
