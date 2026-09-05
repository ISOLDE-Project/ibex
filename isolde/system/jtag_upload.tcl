
# 
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
    reg pc 0x00100080
    resume

}
# ################################3

proc upload {app_name} {
    set APP_PATH ./sw/bin
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
    set APP_ROOT "./sw/bin"

    if {![file isdirectory $APP_ROOT]} {
        error "Applications directory not found: $APP_ROOT"
    }

    set apps {}
    _scan_apps $APP_ROOT apps

    if {[llength $apps] == 0} {
        puts "No application image pairs found under $APP_ROOT"
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
    puts "****   nxp_upload <app_name>   --> uploads the nxp application to the target"
}



welcome