
reset halt 

#riscv set_mem_access progbuf
riscv set_mem_access sysbus

reg pc 0x00100080
resume
#reset halt
#read_memory 0x80000000  32 1 phys
#shutdown
