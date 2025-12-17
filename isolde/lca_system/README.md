# ISOLDE Loosely-coupled accelerator (LCA) model. 
## [REDMULE](https://github.com/ISOLDE-Project/redmule) hardware accelerator
Details about the accelerator are [here](https://github.com/ISOLDE-Project/redmule?tab=readme-ov-file#redmule)
## Prerequisites
in folder **isolde/lca_system**:  
```sh
. ./eth.sh
```
## Building Simulation
in folder **isolde/lca_system**:  
* get a clean slate:
```sh
make rtl-update
```
make sure you have simulation data for the hardware accelerator
```sh
make TEST=redmule_test golden
```
### Build scratchpad memory simulation (SPM, NO JTAG )
it will execute *isolde/sw/redmule128b_test*
```sh
make -f ./Makefile.systca  veri-clean verilate test-build veri-run
```
for a different test from *isolde/sw/<app_test>*:
```sh
make -f ./Makefile.systca TEST=xmas_test veri-clean verilate test-build veri-run
```

### Build scratchpad memory simulation (SPM, JTAG simulation)
it will load into system memmories *isolde/sw/redmule128b_test*
```sh
make -f ./Makefile.wrapper veri-clean verilate veri-run
```
for a different test from *isolde/sw/<app_test>*, use openocd scripts(JTAG), i.e. *isolde/lca_system/load_and_run.tcl*


### Build simple system(no scratchpad memory)
```sh
make  veri-clean verilate
make TEST=redmule test-clean test-build veri-run
```
or, with code memory latency
```sh
make IMEM_LATENCY=1  rtl-update veri-clean verilate
```

### Toolchain
LLVM is the default toolchain   
for **gcc** you specify:

```sh
make  COMPILER=gcc PE=redmule TEST=redmule test-clean test-build veri-run
```


# other tests
## llvm

```sh
make   TEST=dhrystone test-clean test-build veri-run
```
Output should be similar to this:
```
Cycles for one run through Dhrystone:         442
                                              44231 cycles / 100 runs
Dhrystones per 1000 cycle:                     2
[TB LCA] @ t=210212 - Success!
[TB LCA] @ t=210212 - errors=00000000
- /ubuntu_20.04/home/ext/tristan-project/ibex.tca/isolde/lca_system/tb/tb_lca_system.sv:513: Verilog $finish
```
## gcc
```sh
make   COMPILER=gcc TEST=dhrystone test-clean test-build veri-run
```
Output should be similar to this:
```
Cycles for one run through Dhrystone:         729
                                              72920 cycles / 100 runs
Dhrystones per 1000 cycle:                     1
[TB LCA] @ t=272960 - Success!
[TB LCA] @ t=272960 - errors=00000000
- /ubuntu_20.04/home/ext/tristan-project/ibex.tca/isolde/lca_system/tb/tb_lca_system.sv:513: Verilog $finish
```


# Debug Module

Assuming working directory *isolde/lca_system* and each command from bellow in a separate terminal window.  
1. start simulation
```sh
. ./eth.sh
make DBG_MODULE=1 veri-clean verilate
make DBG_MODULE=1 TEST=hello_test test-clean test-build  veri-run
```
or  
```sh
make DBG_MODULE=1 ENABLE_SPM=1 TEST=redmule_test veri-clean verilate  test-clean test-build veri-run
```
  

2. start openocd
```sh
. ./eth.sh
openocd -f isolde.cfg 
```
3. start telnet connection
```sh
telnet localhost 4444
```
In the telnet terminal type:   
```
reset halt
reg pc 0x100000
resume
shutdown
```
or 
In the telnet terminal type( make sure that your working directory is **isolde/lca_system)**:   
```
source ./read_test.tcl
```
or
```
source imem_test.tcl
```
### kill telnet connection
```sh
lsof -i :6666
```
Output:
```
COMMAND   PID USER   FD   TYPE    DEVICE SIZE/OFF NODE NAME
openocd 27459  dan    5u  IPv4 558111571      0t0  TCP localhost:6666 (LISTEN)
```
```sh
kill -9 27459
```
# OpenOCD General Commands
[https://openocd.org/doc/html/General-Commands.html?utm_source=chatgpt.com](https://openocd.org/doc/html/General-Commands.html?utm_source=chatgpt.com)
# Known issues
 RISC-V memory access method(s) shall be used as follow:
 - *progbuf*  for reading/writting dmem and stack
 - *sysbus*   for reading/writting imem

 # Build the fpga simulation
 ```sh
  make -f Makefile.wrapper  veri-clean verilate veri-run
 ```