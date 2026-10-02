# ---------------------------------------------------------------------------
# uart_test.tcl - UART print helpers for the ISOLDE SoC over OpenOCD
#
# Source it from the telnet prompt (or from the OpenOCD cfg, after `init`):
#
#     > source uart_test.tcl
#     > write_uart_info "hello world"
#     uart tx: hello world
#
# Other forms:
#     write_uart_info hello world      ;# quotes are optional
#     write_uart_info -n "no newline"  ;# suppress the trailing CR LF
#     write_uart_char 0x41             ;# one raw byte
#     uart_test                        ;# the original hello-world self-test
#
# Note: output in the telnet window comes from `echo`, not `puts` - `puts`
# goes to the OpenOCD server's own stdout/log, which is why the previous
# version printed nothing in the telnet session.
# ---------------------------------------------------------------------------

# --- configuration ---------------------------------------------------------

# MMADDR_PRINT, see isolde/system/bsp/simple_system_regs.h.
# A write emits the low byte; a read returns the last byte written.
set UART_TX_ADDR 0x80000004
set UART_WIDTH   32

# Appended by write_uart_info unless -n is given. CR first, then LF, so a
# plain serial terminal returns to column 0.
set UART_EOL {0x0D 0x0A}

# The debug module reaches the MMIO window over the system bus, not progbuf.
riscv set_mem_access sysbus

# --- character -> code table -----------------------------------------------
# Built from `format %c` rather than `scan`, so it does not depend on which
# Jim Tcl build OpenOCD was linked against.
array unset UART_ORD
for {set i 1} {$i < 128} {incr i} {
    set UART_ORD([format %c $i]) $i
}

# --- primitives ------------------------------------------------------------

# Write one byte and return what the register reads back (the TX echo).
proc write_uart_char {code} {
    global UART_TX_ADDR UART_WIDTH
    write_memory $UART_TX_ADDR $UART_WIDTH $code phys
    set rb [lindex [read_memory $UART_TX_ADDR $UART_WIDTH 1 phys] 0]
    return [expr {$rb & 0xFF}]
}

# Write a string. Returns nothing, so the telnet session shows the `echo`
# line once instead of echoing the result a second time.
proc write_uart_info {args} {
    global UART_ORD UART_EOL

    set eol 1
    while {[llength $args] > 0 && [string match "-*" [lindex $args 0]]} {
        switch -- [lindex $args 0] {
            -n      { set eol 0 }
            --      { set args [lrange $args 1 end]; break }
            default { echo "write_uart_info: unknown option [lindex $args 0]"
                      return "" }
        }
        set args [lrange $args 1 end]
    }

    if {[llength $args] == 0} {
        echo "usage: write_uart_info \[-n\] <text>"
        return ""
    }

    set text [join $args " "]
    set seen ""
    set bad  0

    foreach ch [split $text ""] {
        if {![info exists UART_ORD($ch)]} {
            incr bad
            continue
        }
        append seen [format %c [write_uart_char $UART_ORD($ch)]]
    }

    if {$eol} {
        foreach code $UART_EOL { write_uart_char $code }
    }

    # $seen is rebuilt from the read-back values, so a mismatch against the
    # text you typed means the write did not land.
    echo "uart tx: $seen"
    if {$bad} {
        echo "write_uart_info: skipped $bad non-ASCII character(s)"
    }
    if {$seen ne $text} {
        echo "write_uart_info: WARNING read-back differs from '$text'"
    }
    return ""
}

# --- self-test -------------------------------------------------------------

proc uart_test {} {
    write_uart_info "hello world"
}

echo "uart_test.tcl loaded - try: write_uart_info \"hello world\""