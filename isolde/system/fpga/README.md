# Vivado / Xilinx flow

All commands are run from `isolde/system/fpga`:

```sh
make help          # shows the current BOARD / CLUSTER / ENABLE_SPM and the targets
make boards        # lists the available board profiles
```

## Quick start

```sh
make cfg BOARD=zcu104            # select the board (writes board/xilinx.cfg)
make clean clean-vivado impl     # full build, ends with a bitstream
```

Non-cluster build (`aida_top`, no SPM, no accelerators):

```sh
make -f Makefile.nospm clean clean-vivado impl
```

> **Known blocker for `CLUSTER=0`:** `rtl/isolde_exec_block.sv` references
> `xif_issue_if.hwe_id`, `.interrupt_enable_mask`, `.cluster_status`,
> `.ip_clear`, `.ip_clear_en`, but `vendor/core-v-xif/rtl/isolde_cv_x_if.sv`
> declares those interface members only under `` `ifdef REDMULE_CLUSTER ``.
> Any build without that define therefore fails to elaborate — simulation
> included. Guard the uses in `isolde_exec_block.sv` to unblock it. The
> Makefile prints a warning when `CLUSTER=0`.

## How it works

This mirrors the Verilator flow (`isolde/mk/verilator-build.mk` +
`slang-build.mk`) exactly: **flist first, slang trims it, tcl is generated
last** — not a Vivado-specific tcl assembled up front and trimmed after the
fact. The project is still assembled from two independently generated source
lists:

1. **fusesoc** — `ibex_synth.flist` runs `fusesoc run --target=synth
   --tool=verilator` on `isolde:ibex:lca_dm_system`. `--target=synth` is what
   selects `toplevel: ibex_top`, the `files_synth` fileset and the synth
   parameter defaults — the same as before. `--tool=verilator` only swaps the
   *output format*: instead of fusesoc's own Vivado backend emitting tcl, its
   Verilator backend emits a plain command file (`.vc`), the very same dialect
   `ibex_sim.flist` uses. `util/transform_paths.py` (the sim flow's own
   utility, unchanged) makes the paths absolute.
2. **bender** — `isolde_synth.flist` runs `bender script verilator
   --no-default-target $(common_targs) -t xilinx [-D REDMULE_CLUSTER]`,
   covering the ISOLDE SoC plus `fpga/rtl/xilinx_aida.sv`, in the same
   command-file dialect.

   **Why `--no-default-target` and not just `script verilator` as-is?**
   Bender injects per-format implicit defines: `script vivado` silently adds
   `TARGET_FPGA` / `TARGET_SYNTHESIS` / `TARGET_VIVADO`, `script verilator`
   adds `TARGET_VERILATOR` instead. `` `ifdef TARGET_VERILATOR `` guards real
   behavioural differences throughout the ISOLDE SoC (`aida.sv`,
   `rv_domain.sv`, `isolde_cluster.sv`, `isolde_tile.sv`, `aida_io*.sv`,
   `cluster_top.sv`, `aida_top.sv`, `isolde_uart_top.sv` all branch on it —
   simulation shortcuts, not just cosmetics), and `` `ifndef TARGET_SYNTHESIS ``
   guards non-synthesisable behavioural models in `tech_cells_generic`'s
   `tc_sram*.sv`. Silently defining `TARGET_VERILATOR` for a real bitstream
   build would not fail synthesis — it would synthesize the *wrong hardware*.
   `isolde/mk/vivado.mk` suppresses bender's implicit defines with
   `--no-default-target` and adds back exactly the three `script vivado`
   would have added (never `TARGET_VERILATOR`); with that flag, `script
   verilator` and `script vivado` emit identical defines otherwise, so this
   really is only a format swap.

3. **slang** trims the merge of the two flists down to the modules reachable
   from the top (`SLANG_TRIM=1`, default) — see *Source-list trimming* below.
   `util/flist2vivado_tcl.py` is the *only* place that emits Vivado tcl,
   converting the (trimmed) flist into `add_files` / `set_property
   include_dirs` / `set_property verilog_define` / `set_property generic`.
   Because both halves are merged before tcl is generated, `vivado_synth.tcl`
   is a single, already-unified block — no separate fusesoc-tcl and
   bender-tcl halves to reconcile afterwards.

`tcl/create_project.tcl` then creates the Vivado project, sources
`vivado_synth.tcl`, reads the two out-of-context IPs, adds the board XDC and
sets the top module.

### Source-list trimming

Vivado parses **every** file in `sources_1` while building the compile order, so
a stale source that nothing instantiates can still break the build. The
Verilator flow already curates its list with slang (`<top>_all_deps.f`); the same
treatment applies here, using the exact same two-phase pattern
(`isolde/mk/slang-build.mk`):

```
ibex_synth.flist                 fusesoc --target=synth --tool=verilator
isolde_synth.flist                bender script verilator --no-default-target
  -> util/flist2slang.py         *.slang / *.slang_opts / *.slang_veri_opts
  -> slang --Mmodule --depfile-sort --depfile-trim --ignore-unknown-modules
                                  <top>_synth_deps.f   (phase 1)
  -> util/flist2vivado_tcl.py    vivado_synth.tcl      (options halves + trimmed sources)
```

The command files are derived **from fusesoc's and bender's own flist output**
(via `--tool=verilator` / `script verilator`, not `script vivado`), so the scan
sees exactly the files, defines, include dirs and parameter overrides the
final Vivado tcl will carry — nothing is re-derived in a different format
after the fact.

On the ZCU104 cluster configuration this drops **510 files to 193**. `xilinx_aida`
instantiates seven modules that have no RTL in the list — the unisim primitives
`BUFGCE`, `IBUF`, `IOBUF`, `OBUFT`, the two out-of-context IPs `xilinx_clk_mngr`
and `xilinx_sys_rst` (added later by `read_ip`), and `xpm_memory_spram`. They
are all leaves, so the scan runs with `--ignore-unknown-modules` and the
dependency closure loses nothing.

`make SLANG_TRIM=0 ...` keeps the full list, for a machine without slang —
`flist2vivado_tcl.py` then reads the two full `*.flist` files directly instead
of the trimmed `*_synth_deps.f`.

**What trimming does not do:** it reduces the number of files Vivado sees, it
does not predict Vivado's synthesis subset. slang happily accepts constructs
Vivado rejects (a modport on an unindexed interface array, for one). `make lint`
(`synth_design -lint`) stays the only check that speaks Vivado.

### `make slang-synth`

Strict slang lint of the **FPGA** configuration on the trimmed set. The
Verilator flow's phase 2 only ever covers `aida_tb`, so `xilinx_aida.sv`,
`aida_padframe.sv` and the xilinx side of `cluster_top.sv` were previously never
linted at all.

| script | what it does |
| --- | --- |
| `tcl/create_project.tcl` | creates `vivado/$project`, adds sources, IPs and constraints |
| `tcl/run.tcl` | synthesis + implementation + `write_bitstream` |
| `tcl/synth.tcl` | synthesis only |
| `tcl/run_linter.tcl` | `synth_design -lint` |
| `tcl/report.tcl` | brief timing summary of an existing run |
| `tcl/program_fpga.tcl` | downloads the bitstream |
| `tcl/common.tcl` | shared settings, used by the IP projects |

## Board profiles

A board is a pair of files:

* `board/xilinx_<board>.cfg` — project name, `part`, `board_part`, top module,
  XDC name (and optionally `scripts_vivado_version`)
* `board/<board>.xdc` — pin constraints

`make cfg BOARD=<board>` copies the chosen `.cfg` to `board/xilinx.cfg`, which
is the single file every tcl script sources. `board/xilinx.cfg` is gitignored;
all Vivado targets depend on it, so it is created automatically with the
default `BOARD=zcu104`.

To add a board: drop in the two files, then check the two IPs below — the
clocking wizard is configured for the ZCU104's 300 MHz differential input and
must be re-tuned for a different input clock.

## Out-of-context IPs

`ips/xilinx_clk_mngr` (clocking wizard) and `ips/xilinx_sys_rst`
(`proc_sys_reset`) are built into their own `.xpr` before the main project and
pulled in with `read_ip`. They take `part`/`board_part` from `board/xilinx.cfg`
via `tcl/common.tcl`, and the target clock from the environment:

```sh
FC_CLK_PERIOD_NS=10.0 PER_CLK_PERIOD_NS=20.0 make -C ips/xilinx_clk_mngr all
```

They are rebuilt only when missing. If Vivado reports them as *locked*,
regenerate: `make -C ips/xilinx_clk_mngr clean all`.

## Build configuration

| variable | default | meaning |
| --- | --- | --- |
| `BOARD` | `zcu104` | selects `board/xilinx_<board>.cfg` |
| `CLUSTER` | `1` | `1` → `cluster_top` (`-D REDMULE_CLUSTER`, forces `ENABLE_SPM=1`); `0` → `aida_top` |
| `ENABLE_SPM` | `1` | adds bender target `-t spm` |
| `SLANG_TRIM` | `1` | curate the source list with slang; `0` keeps the full list |
| `SLANG_SYNTH_TOP` | from `_top_module_` | top module the dependency scan starts from |
| `SLANG` | `slang` | slang binary |

`DBG_MODULE=1` is forced, so `TARGET_RV_DEBUG` is always defined and the RISC-V
debug module + JTAG pads are always present.

`CLUSTER` selects the same define (`REDMULE_CLUSTER`) that
`vendor/isolde-soc/fpga/tb/aida_tb.sv` uses, so simulation and FPGA elaborate
the same SoC. Keep them in sync.

## Boot behaviour

`xilinx_aida` has a `BootROMEnable` parameter, defaulted from
`` `ifdef TARGET_RV_DEBUG `` exactly like `aida_tb`:

* `1` → the core boots at `ROM_BOOT_ADDR` (`0x0000_0080`) and parks in
  `isolde_boot_rom` until a debugger loads an image and sets the PC.
* `0` → the core boots at `RV_BOOT_ADDR` (`0x0010_0080`) and immediately runs
  whatever is in the instruction memory.

To override it without editing RTL, add to `tcl/create_project.tcl`:

```tcl
set_property generic {BootROMEnable=0} [current_fileset]
```

## UART / JTAG test

```sh
hexdump -v -e '1/1 "%02X "' /dev/ttyUSB3
minicom -D /dev/ttyUSB3 -b 115200
```

OpenOCD against the board: `openocd-zcu104-digilent-jtag-hs2.cfg`.
