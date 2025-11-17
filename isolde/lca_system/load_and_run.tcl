set APP_NAME hello_test
set APP_PATH ./sw/bin
set INSTR_BIN ${APP_PATH}/${APP_NAME}_ihex-i.hex
set DATA_BIN  $INSTR_BIN
reset halt
riscv set_mem_access sysbus
load_image $INSTR_BIN 0x00100000 ihex
puts "\n✅ Instruction loaded!"
load_image $DATA_BIN  0x00100000 ihex
puts "\n✅ Data loaded!"
#reg pc 0x100080
#resume
#force exit
#shutdown