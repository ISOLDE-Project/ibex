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

The project is assembled from **two independently generated source lists**:

1. **fusesoc** — `make -f Makefile.vivado ... ibex_synth.tcl` runs
   `fusesoc run --target=synth` on `isolde:ibex:lca_dm_system`. That target has
   `toplevel: ibex_top`, so it only covers the **ibex core and the lowRISC
   primitives**. `util/convert_vivado_tcl.py` rewrites its `read_verilog`
   commands into `add_files` form and exports `$ROOT_IBEX` and
   `$ibex_include_dirs`.
2. **bender** — `bender script vivado $(common_targs) -t xilinx [-D REDMULE_CLUSTER]`
   produces `isolde_synth.tcl`, covering the ISOLDE SoC plus
   `fpga/rtl/xilinx_aida.sv`.

`cat ibex_synth.tcl isolde_synth.tcl > vivado_synth.tcl`.

`tcl/create_project.tcl` then creates the Vivado project, sources
`vivado_synth.tcl`, reads the two out-of-context IPs, adds the board XDC and
sets the top module.

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
