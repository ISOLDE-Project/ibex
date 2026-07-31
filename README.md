[Ibex OpenTitan configuration Nightly Regression](https://ibex.reports.lowrisc.org/opentitan/latest/report.html)
<a href="https://ibex.reports.lowrisc.org/opentitan/latest/report.html">
  <img src="https://ibex.reports.lowrisc.org/opentitan/latest/summary.svg">
</a>

# ISOLDE

First time:   
```sh
. ./setup.sh 
```sh
git checkout tmp/exp
git submodule update --init
cd isolde/tca_system/
. ./eth.sh 
bender update
```
* install toolchain

```sh
make -f Makefile.tools
```
otherwise:  
```sh
. ./eth.sh 
```
see also [isolde/simple_system/README.md](isolde/simple_system/README.md)
# Directory structure
```
├── ci
├── doc
├── dv
├── examples
├── formal
├── install
├── isolde          <-- ISOLDE systems
├── lint
├── rtl
├── shared
├── syn
├── util
└── vendor           <-- external IPs
```
## External IPs
external IPs are hosted in vendor folder as git submodules

Steps to add a new IP   
```
git submodule add <ip_url> vendor/<ip>
```
Optional,
```
cd vendor/<ip>
git checkout <branch>
```
Finally:  
```
git commit -m"NEW git submodule: vendor/<ip>"
git push
```
# Miscellaneous
# working on a branch
```sh
git checkout <branch>
git submodule update --init
cd isolde/tca_system/
. ./eth.sh 
bender update
```
## How to List Branches That Contain a Given Commit?
In submodule find the commit id:  
```sh
$ git status
HEAD detached at 89f09db
```
```sh
 $ git branch -r  --contains 89f09db
  origin/isolde/spm
  ```
# merging
```sh
# Step 1: Switch to the target branch isolde/dev
git checkout isolde/dev

# Step 2: Perform the merge using squash
git merge --squash tmp/exp

# Step 3: Resolve all conflicts in favor of 'theirs'
git checkout --theirs .

# Step 4: 
git submodule update --init
#perform tests

# Step 5: Stage the changes after conflict resolution
git add .

# Step 6: Commit the changes with a custom message
git commit -m "Squash merge tmp/exp into isolde/dev using theirs strategy"
```
## recover the branch in a submodule
The problem:
```
git status
HEAD detached at 970dc75
```
The solution:  
```sh
git branch -a -vv
```
the output  
```
* (HEAD detached at 970dc75) 970dc75 cleaned up
  main                       7bcfad6 [origin/main: behind 1] fixed cv_x_if.core
  tmp/yosys                  7bcfad6 fixed cv_x_if.core
  remotes/origin/HEAD        -> origin/main
  remotes/origin/ibex/dev    2f08b24 new:beder file
  remotes/origin/main        970dc75 cleaned up
```
it is observed that remotes/origin/main        **970dc75** corespond to the *(HEAD detached at 970dc75)*. Next step  
```sh
git checkout -b tmp/fix
git add .
git commit 
git switch main
git merge tmp/fix
git push
git branch -d tmp/fix
```
# Open EDA
## Install tools
for a lst of available targets:
```sh
make -f Makefile.tools help
```
## Synthesis
apply patches from isolde/system/patches by running
```sh
make -C isolde/system/patches 
```
output is generated in  
- yosys/out
- yosys/reports  

## RISC-V Domain (rv_domain)
ibex+debug-module+uart-tx-only
```sh
make clean yosys-flist 
make TOP_DESIGN=rv_domain_top    yosys-clean yosys
```
**snippet** from *yosys/reports/rv_domain_top_area.rpt*
```
=== rv_domain_top ===

        +----------Local Count, excluding submodules.
        |        +-Local Area, excluding submodules.
        |        | 
    26128        - wires
    26128        - wire bits
     4002        - public wires
     4002        - public wire bits
      325        - ports
      325        - port bits
    25800 3.93E+05 cells
```

## RISC-V core (rv_core)
ibex
```sh
make clean yosys-flist yosys
```
**snippet** from *yosys/reports/rv_top_area.rpt*:  
```
=== rv_top ===

        +----------Local Count, excluding submodules.
        |        +-Local Area, excluding submodules.
        |        | 
    16912        - wires
    16912        - wire bits
     2193        - public wires
     2193        - public wire bits
      206        - ports
      206        - port bits
    16850  2.6E+05 cells
```

## aida (aida_top)
ibex
```sh
make clean yosys-flist 
make TOP_DESIGN=aida_top  yosys
```
**snippet** from *yosys/reports/aida_top_area.rpt*:  
```
72. Printing statistics.

=== aida_top ===

        +----------Local Count, excluding submodules.
        |        +-Local Area, excluding submodules.
        |        | 
    41823        - wires
    41823        - wire bits
     6008        - public wires
     6008        - public wire bits
        9        - ports
        9        - port bits
    42986 6.35E+05 cells
        6        -   $_DLATCH_N_
```
**Note**:  
Needs fix for *$_DLATCH_N_* nodes.  

## OpenROAD
```sh
make openroad
```
**Note**: only rv_core available 

# Ibex RISC-V Core

Ibex is a production-quality open source 32-bit RISC-V CPU core written in
SystemVerilog. The CPU core is heavily parametrizable and well suited for
embedded control applications. Ibex is being extensively verified and has
seen multiple tape-outs. Ibex supports the Integer (I) or Embedded (E),
Integer Multiplication and Division (M), Compressed (C), and B (Bit
Manipulation) extensions.

<p align="center"><img src="doc/03_reference/images/blockdiagram.svg" width="650"></p>

Ibex was initially developed as part of the [PULP platform](https://www.pulp-platform.org)
under the name ["Zero-riscy"](https://doi.org/10.1109/PATMOS.2017.8106976), and has been
contributed to [lowRISC](https://www.lowrisc.org) who maintains it and develops it further. It is
under active development.

## Configuration

Ibex offers several configuration parameters to meet the needs of various application scenarios.
The options include different choices for the architecture of the multiplier unit, as well as a range of performance and security features.
The table below indicates performance, area and verification status for a few selected configurations.
These are configurations on which lowRISC is focusing for performance evaluation and design verification (see [supported configs](ibex_configs.yaml)).

| Config | "micro" | "small" | "maxperf" | "maxperf-pmp-bmfull" |
| ------ | ------- | --------| ----------| -------------------- |
| Features | RV32EC | RV32IMC, 3 cycle mult | RV32IMC, 1 cycle mult, Branch target ALU, Writeback stage | RV32IMCB, 1 cycle mult, Branch target ALU, Writeback stage, 16 PMP regions |
| Performance (CoreMark/MHz) | 0.904 | 2.47 | 3.13 | 3.13 |
| Area - Yosys (kGE) | 16.85 | 26.60 | 32.48 | 66.02 |
| Area - Commercial (estimated kGE) | ~15 | ~24 | ~30 | ~61 |
| Verification status | Red | Green | Green | Green |

Notes:

* Performance numbers are based on CoreMark running on the Ibex Simple System [platform](examples/simple_system/README.md).
  Note that different ISAs (use of B and C extensions) give the best results for different configurations.
  See the [Benchmarks README](examples/sw/benchmarks/README.md) for more information.
* Yosys synthesis area numbers are based on the Ibex basic synthesis [flow](syn/README.md) using the latch-based register file.
* Commercial synthesis area numbers are a rough estimate of what might be achievable with a commercial synthesis flow and technology library.
* For comparison, the original "Zero-riscy" core yields an area of 23.14kGE using our Yosys synthesis flow.
* Verification status is a rough guide to the overall maturity of a particular configuration.
  Green indicates that verification is close to complete.
  Amber indicates that some verification has been performed, but the configuration is still experimental.
  Red indicates a configuration with minimal/no verification.
  Users must make their own assessment of verification readiness for any tapeout.
* v.1.0.0 of the RISC-V Bit-Manipulation Extension is supported as well as the remaining sub-extensions of draft v.0.93 of the bitmanip spec.
  The latter are *not ratified* and there may be changes before ratification.
  See [Standards Compliance](https://ibex-core.readthedocs.io/en/latest/01_overview/compliance.html) in the Ibex documentation for more information.

## Documentation

The Ibex user manual can be
[read online at ReadTheDocs](https://ibex-core.readthedocs.io/en/latest/). It is also contained in
the `doc` folder of this repository.

## Examples

The Ibex repository includes [Simple System](examples/simple_system/README.md).
This is an intentionally simple integration of Ibex with a basic system that targets simulation.
It is intended to provide an easy way to get bare metal binaries running on Ibex in simulation.

A more complete example can be found in the [Ibex Demo System repository](https://github.com/lowrisc/ibex-demo-system).
In particular it includes a integration of the [PULP RISC-V debug module](https://github.com/pulp-platform/riscv-dbg).
It targets the [Arty A7 FPGA board from Digilent](https://digilent.com/shop/arty-a7-artix-7-fpga-development-board/) and supports debugging via OpenOCD and GDB over USB (no external JTAG probe required).
The Ibex Demo System is maintained by lowRISC but is not an official part of Ibex.

## Contributing

We highly appreciate community contributions. To ease our work of reviewing your contributions,
please:

* Create your own branch to commit your changes and then open a Pull Request.
* Split large contributions into smaller commits addressing individual changes or bug fixes. Do not
  mix unrelated changes into the same commit!
* Write meaningful commit messages. For more information, please check out the [contribution
  guide](https://github.com/lowrisc/ibex/blob/master/CONTRIBUTING.md).
* If asked to modify your changes, do fixup your commits and rebase your branch to maintain a
  clean history.

When contributing SystemVerilog source code, please try to be consistent and adhere to [our Verilog
coding style guide](https://github.com/lowRISC/style-guides/blob/master/VerilogCodingStyle.md).

When contributing C or C++ source code, please try to adhere to [the OpenTitan C++ coding style
guide](https://opentitan.org/book/doc/contributing/style_guides/c_cpp_coding_style.html).
All C and C++ code should be formatted with clang-format before committing.
Either run `clang-format -i filename.cc` or `git clang-format` on added files.

To get started, please check out the ["Good First Issue"
 list](https://github.com/lowrisc/ibex/issues?q=is%3Aissue+is%3Aopen+label%3A%22Good+First+Issue%22).

## Issues and Troubleshooting

If you find any problems or issues with Ibex or the documentation, please check out the [issue
 tracker](https://github.com/lowrisc/ibex/issues) and create a new issue if your problem is
not yet tracked.

## Questions?

Do not hesitate to contact us, e.g., on our public [Ibex channel on
Zulip](https://lowrisc.zulipchat.com/#narrow/stream/198227-ibex)!

## License

Unless otherwise noted, everything in this repository is covered by the Apache
License, Version 2.0 (see LICENSE for full text).

## Credits

Many people have contributed to Ibex through the years. Please have a look at
the [credits file](CREDITS.md) and the commit history for more information.
