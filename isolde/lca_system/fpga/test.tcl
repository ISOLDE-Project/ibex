# ===============================================
# UART transmission test: send "hello" over UART
# ===============================================

set uart_tx_addr 0x80000004    ;# TX register base
set uart_status_addr 0x80000008 ;# Optional: status register (if available)
set uart_tx_ready_mask 0x1      ;# Assume bit 0 means TX ready

set msg "hello"
puts "---------------------------------------------"
puts "Sending string \"$msg\" over UART..."

foreach c [split $msg ""] {
    set ascii_val [scan $c %c]

    # Optional: wait until UART TX ready (if status register exists)
    # while {1} {
    #     set status [lindex [read_memory $uart_status_addr 32 1 phys] 0]
    #     if {[expr {$status & $uart_tx_ready_mask}] != 0} {
    #         break
    #     }
    # }

    set hex_val [format "0x%08X" $ascii_val]
    puts "Writing '$c' ($hex_val) to UART TX..."
    write_memory $uart_tx_addr 32 $hex_val phys
    after 10  ;# small delay (10ms)
}

puts "✅ UART transmission completed. Check Minicom output!"