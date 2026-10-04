# OpenOCD helper: read the CoreMark progress beacon WITHOUT halting the core.
#
# Halting a running program is not reliable on this SoC (the debug ROM can end
# up storing to an unmapped address, after which the core never responds).
# System-bus reads go through the debug module's SBA port instead and do not
# disturb the hart, so use them to see how far CoreMark got.
#
# Usage (after load_and_run / resume, in the OpenOCD telnet console):
#   source isolde/sw/coremark/coremark_peek.tcl
#   coremark_peek 0x00110bf0        ;# address printed as "Progress beacon"
#   coremark_watch 0x00110bf0 10    ;# 10 samples, one per second
#
# The address is also in sw/bin/coremark.elf.map (symbol coremark_beacon).
# OpenOCD may print "Failed to read priv register" while the hart is running;
# that is harmless - the system-bus read still completes.

proc coremark_stage_name {s} {
    switch -- $s {
        0 { return "boot (port not entered yet)" }
        1 { return "init (portable_init ran; list/matrix/state setup)" }
        2 { return "timing (benchmark iterations running)" }
        3 { return "timed (iterations done; CRCs and report next)" }
        4 { return "report (portable_fini printing results)" }
        5 { return "exit (_Exit called)" }
        default { return "unknown" }
    }
}

proc coremark_peek {addr} {
    riscv set_mem_access sysbus
    set w [read_memory $addr 32 6]
    lassign $w magic stage printfs cycles failures last_fmt
    # read_memory returns 0x-prefixed strings; normalise to integers
    foreach v {magic stage printfs cycles failures last_fmt} { set $v [expr {[set $v]}] }
    if {$magic != 0xc0e5beac} {
        puts [format "beacon @0x%08x: magic 0x%08x (expected 0xc0e5beac) - wrong address, or portable_init not reached" $addr $magic]
        return
    }
    puts [format "beacon @0x%08x: stage %d = %s" $addr $stage [coremark_stage_name $stage]]
    puts [format "  ee_printf calls %d, last format @0x%08x, cycles %d, failures %d" \
              $printfs $last_fmt $cycles $failures]
    # Do NOT read aida_perfcnt (0x8000000c) from here: the debug module's
    # system-bus map (dm_sba_map in isolde_cluster.sv) does not include it,
    # and an unmapped SBA access never completes.
}

proc coremark_watch {addr {samples 10}} {
    for {set i 0} {$i < $samples} {incr i} {
        coremark_peek $addr
        sleep 1000
    }
}
