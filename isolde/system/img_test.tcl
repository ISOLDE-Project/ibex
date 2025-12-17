set APP_NAME hello_test
set APP_PATH ./sw/bin
set INSTR_IMG ${APP_PATH}/${APP_NAME}-m.ihex
#set DATA_IMG_OFFSET  0x10000
set DATA_IMG  ${APP_PATH}/${APP_NAME}-d.ihex

reset halt
halt
riscv set_mem_access sysbus
echo  " ----"
puts "INSTR_IMG: $INSTR_IMG"
puts "DATA_IMG:  $DATA_IMG"
echo  " ----"
puts "\n⚠️ instr mem head"
puts " @0x00100000: [read_memory 0x00100000 32 4 phys]"
puts " @0x00100080: [read_memory 0x00100080 32 4 phys]"
verify_image $INSTR_IMG 
echo  " ----"
puts "\n⚠️ data mem head!"
puts " @0x00110000: [read_memory 0x00110000 32 4 phys]"
puts " @0x00110080: [read_memory 0x00110080 32 4 phys]"
verify_image $DATA_IMG 
#reg pc 0x00100080
#resume
#force exit
#shutdown
