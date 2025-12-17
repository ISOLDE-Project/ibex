reset halt
riscv set_mem_access sysbus

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
    0x0000000A 
    0x0000000D
}

foreach word $hello_world {
    write_memory $uart_addr $width $word phys
    #after 100               ;# <-- wait 100 ms before next character
}

puts "\n✅ Message sent!"
