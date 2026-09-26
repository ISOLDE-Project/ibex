
# 
source ./fpga/uart_test.tcl
# global config
set APP_PATH ./app-images

proc nxp_upload {app_name} {
    set APP_PATH ./nxp-ro/${app_name}
    set INSTR_IMG "${APP_PATH}/omp_test-m.ihex"
    set DATA_IMG  "${APP_PATH}/omp_test-d.ihex"

    reset halt
    halt

    riscv set_mem_access sysbus

    puts " ----\n"
    puts "INSTR_IMG: $INSTR_IMG"
    puts "DATA_IMG:  $DATA_IMG"
    puts " ----\n"

    load_image   $INSTR_IMG
    verify_image $INSTR_IMG
    puts "\n✅ instr mem loaded!"
# 
    load_image   $DATA_IMG
    verify_image $DATA_IMG
    puts "\n✅ data mem loaded!"

#   soft restart
    write_uart_info "Starting nxp application: $app_name"
    reg pc 0x00100080
    resume

}
# ################################3

# upload <app_name> [case]: with a case, also load <app_name>-<case>.ihex
# (radar_attention: `make TEST=radar_attention cases`) before starting.
proc upload {app_name {case ""}} {
    global APP_PATH 
    set INSTR_IMG "${APP_PATH}/${app_name}-m.ihex"
    set DATA_IMG  "${APP_PATH}/${app_name}-d.ihex"

    reset halt
    halt

    riscv set_mem_access sysbus

    puts " ----\n"
    puts "INSTR_IMG: $INSTR_IMG"
    puts "DATA_IMG:  $DATA_IMG"
    puts " ----\n"

    load_image   $INSTR_IMG
    verify_image $INSTR_IMG
    puts "\n✅ instr mem loaded!"
# 
    load_image   $DATA_IMG
    verify_image $DATA_IMG
    puts "\n✅ data mem loaded!"

    if {$case ne ""} {
        set CASE_IMG "${APP_PATH}/${app_name}-${case}.ihex"
        load_image   $CASE_IMG
        verify_image $CASE_IMG
        puts "\n✅ test case loaded: $case"
    }

#   soft restart
    reg pc 0x00100080
    resume

}

proc soft_reset {} {
    puts " ----\n"
    puts "Soft reset\n"
    puts " ----\n"
    halt
    reg pc 0x00100080
    resume
}


proc _scan_apps {dir apps_var} {
    upvar $apps_var apps

    foreach path [glob -nocomplain [file join $dir *]] {
        if {[file isdirectory $path]} {
            _scan_apps $path apps
            continue
        }

        set filename [file tail $path]

        if {[regexp {^(.*)-m\.ihex$} $filename match app_name]} {
            set data_img [file join [file dirname $path] "${app_name}-d.ihex"]

            if {[file exists $data_img]} {
                lappend apps $app_name
            }
        }
    }
}

proc list_apps {} {
    global APP_PATH
    if {![file isdirectory $APP_PATH]} {
        error "Applications directory not found: $APP_PATH"
    }

    set apps {}
    _scan_apps $APP_PATH apps

    if {[llength $apps] == 0} {
        puts "No application image pairs found under $APP_PATH"
        return
    }

    set last ""
    set have_last 0

    foreach app_name [lsort $apps] {
        if {!$have_last || $app_name ne $last} {
            puts $app_name
            set last $app_name
            set have_last 1
        }
    }
}

proc welcome {} {
    puts "** INFO ** Port:            /dev/ttyUSB3    ********************************"
    puts "** INFO ** UART Baudrate:   921600          ********************************"
    puts "****************   jtag commands            ********************************"
    puts "****   soft_reset              --> performs a soft reset"
    puts "****   list_apps               --> lists available applications"
    puts "****   upload <app_name>       --> uploads the application to the target"
    puts "****   upload <app_name> <case> --> ... and loads <app_name>-<case>.ihex"
    puts "****   nxp_upload <app_name>   --> uploads the nxp application to the target"
}



welcome