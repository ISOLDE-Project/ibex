reset halt 
# test.tcl - OpenOCD Tcl script to write and verify memory contents
#riscv set_mem_access progbuf
riscv set_mem_access sysbus

#reset halt 
set width 32

set uart_addr 0x80000004
set hello_world {
    0x00000068
    0x00000065
    0x0000006C
    0x0000006C
    0x0000006F
    0x00000020
    0x00000077
    0x0000006F
    0x00000072
    0x0000006C
    0x00000064
}

foreach word $hello_world {
    write_memory $uart_addr $width $word phys
    set tx_echo [read_memory $uart_addr $width 1 phys]
    set ascii_char [format "%c"  $tx_echo] 

    # Print character without newline separation
    puts -nonewline $ascii_char
}
puts ""  ;# Print newline after the message

#shutdown
