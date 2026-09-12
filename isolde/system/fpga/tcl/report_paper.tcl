# Batch entry point for `make rpt-paper`.
# Requires an existing implemented project and tcl/export_vivado_reports.tcl.
set fpga_dir [file normalize [file join [file dirname [info script]] ..]]

if {[catch {
    source [file join $fpga_dir board xilinx.cfg]
    set project_file [file join $fpga_dir vivado $project "${project}.xpr"]
    if {![file isfile $project_file]} {
        error "Vivado project not found: $project_file. Create and implement it first."
    }

    open_project $project_file
    open_run impl_1

    # The exporter records checkout provenance and writes relative to pwd.
    set paper_repo_root [file normalize [file join $fpga_dir .. .. ..]]
    cd $fpga_dir
    source [file join $fpga_dir tcl export_vivado_reports.tcl]

    # The exporter collects all available reports before reporting failures.
    # Make must also signal a partial export to batch callers.
    if {[info exists ::isolde_paper::failures] && $::isolde_paper::failures > 0} {
        error "$::isolde_paper::failures report exports failed; inspect export_status.txt in $::isolde_paper::outdir"
    }
    close_project
} message]} {
    puts stderr "ERROR: $message"
    catch {close_project}
    exit 1
}

exit 0
