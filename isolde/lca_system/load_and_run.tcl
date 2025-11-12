set APP_NAME hello_test
set APP_PATH ./sw/bin
set INSTR_BIN ${APP_PATH}/${APP_NAME}_ihex-i.hex
set DATA_BIN  $INSTR_BIN
reset halt
load_image $INSTR_BIN 0x00100000 bin
load_image $DATA_BIN  0x00100000 bin
reg pc 0x100080
resume
#force exit
#shutdown
