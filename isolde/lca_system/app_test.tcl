reset halt 
# Specify which RISC-V memory access method(s) shall be used, ie sysbus - Access memory via RISC-V Debug System Bus interface. 
riscv set_mem_access sysbus
# Define the address and values
set boot_addr 0x100000
set width 32

reg pc $boot_addr
resume
#shutdown

