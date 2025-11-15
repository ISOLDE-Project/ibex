set APP_NAME hello_test
set APP_PATH ./sw/bin
set INSTR_IMG ${APP_PATH}/${APP_NAME}_ihex-i.hex
set DATA_IMG  ${APP_PATH}/${APP_NAME}_ihex-d.hex

reset halt
halt
riscv set_mem_access sysbus
puts "INSTR_IMG: $INSTR_IMG"
puts "DATA_IMG:  $DATA_IMG"
halt 
load_image $INSTR_IMG  
halt
verify_image $INSTR_IMG 
puts "\n✅ instr mem loaded!"
puts " @0x00100000: [read_memory 0x00100000 32 4 phys]"
puts " @0x00100080: [read_memory 0x00100080 32 4 phys]"
load_image $DATA_IMG  
halt
#verify_image $DATA_IMG 
puts "\n✅ data mem loaded!"
puts " @0x00110000: [read_memory 0x00110000 32 4 phys]"
puts " @0x00110080: [read_memory 0x00110080 32 4 phys]"

#reg pc 0x00100080
#resume
#force exit
#shutdown
