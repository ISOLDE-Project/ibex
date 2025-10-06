reset halt 
# test.tcl - OpenOCD Tcl script to write and verify memory contents
#riscv set_mem_access progbuf
riscv set_mem_access sysbus

#reset halt 
set width 32

set test_addrs {0x00100000  0x00140000}

# Generate random 32-bit values for each address
set tests {}
foreach addr $test_addrs {
    # Generate a random 32-bit integer
    # expr {int(rand() * 0xFFFFFFFF)} → 0 to 0xFFFFFFFF
    set rand_val [expr {int(rand() * 0xFFFFFFFF)}]

    # Format it as a hex word (0xXXXXXXXX)
    set hex_val [format "0x%08X" $rand_val]

    # Append the address–value pair to the tests list
    lappend tests [list $addr [list $hex_val]]
}

# Print out generated pairs (for debugging)
puts "Generated test data:"
foreach test $tests {
    puts $test
}

set overall_match 1

foreach test $tests {
    set addr [lindex $test 0]
    set expected_values [lindex $test 1]

    puts "---------------------------------------------"
    puts "Writing memory at $addr..."
    write_memory $addr $width $expected_values phys

    puts "Reading memory at $addr..."
    set read_values [read_memory $addr $width [llength $expected_values] phys]

    puts "Verifying memory contents at $addr..."
    set match 1
    for {set i 0} {$i < [llength $expected_values]} {incr i} {
        set expected [lindex $expected_values $i]
        set actual [lindex $read_values $i]
        if {$expected != $actual} {
            puts "ERROR: Mismatch at $addr word $i: expected $expected, got $actual"
            set match 0
        }
    }

    if {$match} {
        puts "SUCCESS: Memory at $addr matches expected values."
    } else {
        puts "FAILURE: Memory verification failed at $addr."
        set overall_match 0
    }
}

puts "============================================="
if {$overall_match} {
    puts "ALL TESTS PASSED."
} else {
    puts "ONE OR MORE TESTS FAILED."
}

#shutdown
