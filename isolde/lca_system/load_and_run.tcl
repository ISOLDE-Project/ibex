set APP_NAME hello_test
set APP_PATH ./sw/bin
set INSTR_IMG ${APP_PATH}/${APP_NAME}_ihex-i.hex
set DATA_IMG_OFFSET  0x10000
#set DATA_IMG  ${APP_PATH}/${APP_NAME}_ihex-i.hex

reset halt
halt
riscv set_mem_access sysbus
echo  " ----"
puts "INSTR_IMG:        $INSTR_IMG"
puts "DATA_IMG_OFFSET:  $DATA_IMG_OFFSET"
echo  " ----"
load_image   $INSTR_IMG  
verify_image $INSTR_IMG 
puts "\n✅ instr mem loaded!"
puts " @0x00100000: [read_memory 0x00100000 32 4 phys]"
puts " @0x00100080: [read_memory 0x00100080 32 4 phys]"
echo  " ⚠️"
puts " @0x00110000: [read_memory 0x00110000 32 4 phys]"
puts " @0x00110080: [read_memory 0x00110080 32 4 phys]"
load_image   $INSTR_IMG $DATA_IMG_OFFSET
verify_image $INSTR_IMG $DATA_IMG_OFFSET
puts "\n✅ data mem loaded!"
puts " @0x00110000: [read_memory 0x00110000 32 4 phys]"
puts " @0x00110080: [read_memory 0x00110080 32 4 phys]"

#reg pc 0x00100080
#resume
#force exit
#shutdown
