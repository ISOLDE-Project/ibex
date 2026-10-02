# Export evidence for an ISOLDE/Ibex paper from an OPEN IMPLEMENTED DESIGN.
# In the Vivado Tcl console:
#   open_run impl_1
#   set paper_repo_root {/absolute/path/to/ibex} ;# optional checkout provenance
#   source {/absolute/path/to/export_vivado_reports.tcl}
#
# Reports describe the currently open design. This script never launches runs,
# changes timing constraints, imports switching activity, or programs hardware.
# An export succeeding does not mean the design passes any reported check.
# No Vivado execution was available when this script was prepared.

namespace eval ::isolde_paper {
    variable outdir
    variable status_file
    variable failures 0

    proc property_or_note {object property} {
        if {$object eq ""} { return "UNAVAILABLE" }
        if {[catch {get_property $property $object} value]} {
            return "UNAVAILABLE: $value"
        }
        return $value
    }

    proc emit {filename command} {
        variable status_file
        variable failures
        puts "Exporting $filename"
        if {[catch {uplevel #0 [list {*}$command]} message]} {
            incr failures
            puts $status_file "EXPORT_FAILED: $filename\n  $message"
            puts "WARNING: Could not export $filename: $message"
        } else {
            puts $status_file "GENERATED: $filename"
        }
        flush $status_file
    }

    proc report {filename command} {
        variable outdir
        emit $filename [list {*}$command -file [file join $outdir $filename]]
    }

    proc main {} {
        variable outdir
        variable status_file
        variable failures
        set failures 0

        if {[catch {current_design} design] || $design eq ""} {
            error "Open the completed implemented design before sourcing this script."
        }

        # Always create a fresh directory to avoid mixing different exports.
        set stamp [clock format [clock seconds] -format {%Y%m%d_%H%M%S}]
        set base [file normalize [file join [pwd] "paper_reports_$stamp"]]
        set outdir $base
        set suffix 1
        while {[file exists $outdir]} {
            set outdir "${base}_$suffix"
            incr suffix
        }
        file mkdir $outdir
        set status_file [open [file join $outdir export_status.txt] w]
        puts $status_file "GENERATED means exported, not passed. Review each report."
        puts $status_file "Design: $design"

        set meta [open [file join $outdir build_metadata.txt] w]
        puts $meta "Export time: [clock format [clock seconds] -format {%Y-%m-%dT%H:%M:%SZ} -gmt 1]"
        puts $meta "Vivado: [version]"
        puts $meta "Open design: $design"
        puts $meta "Device: [property_or_note $design PART]"
        puts $meta "Report directory: $outdir"
        puts $meta "Stage: user must confirm final routed implementation; inspect route_status.rpt."

        if {![catch {current_project} project] && $project ne ""} {
            puts $meta "Project: $project"
            foreach prop {DIRECTORY PART BOARD_PART} {
                puts $meta "Project $prop: [property_or_note $project $prop]"
            }
        }
        if {![catch {current_fileset} fileset] && $fileset ne ""} {
            foreach prop {TOP VERILOG_DEFINE GENERIC} {
                puts $meta "Fileset $prop: [property_or_note $fileset $prop]"
            }
        }
        if {![catch {get_runs -quiet} runs]} {
            foreach run $runs {
                puts $meta "Run: $run"
                foreach prop {STATUS PROGRESS STRATEGY DIRECTORY} {
                    puts $meta "  $prop: [property_or_note $run $prop]"
                }
            }
        }

        puts $meta "\nThe current checkout below is NOT proof of the revision used to build the open design."
        if {[info exists ::paper_repo_root]} {
            set root [file normalize $::paper_repo_root]
            puts $meta "Checkout path at export: $root"
            foreach cmd {
                {rev-parse HEAD}
                {status --short}
                {submodule status --recursive}
            } {
                if {[catch {exec git -C $root {*}$cmd} result]} {
                    puts $meta "git $cmd: UNAVAILABLE: $result"
                } else {
                    puts $meta "git $cmd:\n$result"
                }
            }
        } else {
            puts $meta "Checkout provenance: not recorded; paper_repo_root was not set."
        }
        puts $meta "\nAuthor: supply actual build revision, local changes, platform parameters and build command."
        puts $meta "Author: supply workload, clock, voltage/temperature and activity provenance for power estimates."
        close $meta

        report utilization.rpt {report_utilization}
        report utilization_hierarchical.rpt {
            report_utilization -hierarchical 
        }
        report timing_summary.rpt {
            report_timing_summary -delay_type min_max -max_paths 10
            -check_timing_verbose -report_unconstrained
        }
        report route_status.rpt {report_route_status}
        report clocks.rpt {report_clocks}
        report clock_interaction.rpt {report_clock_interaction}
        report timing_exceptions.rpt {report_exceptions}
        report timing_exceptions_ignored.rpt {report_exceptions -ignored}
        report drc.rpt {report_drc}
        report methodology.rpt {report_methodology}
        report cdc.rpt {report_cdc -details}
        report power.rpt {report_power -hierarchical_depth 8}
        emit constraints_effective.xdc [list write_xdc -force -constraints all \
            [file join $outdir constraints_effective.xdc]]

        puts $status_file "\nExport failures: $failures"
        close $status_file
        puts "Reports exported to: $outdir"
        puts "Export failures: $failures. Inspect export_status.txt and all report findings."
        puts "Zip this directory and include your build logs and active configuration."
    }
}

::isolde_paper::main
