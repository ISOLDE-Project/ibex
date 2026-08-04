# ISOLDE 
## Generate test data
```sh
cd isolde/system
. ./eth.sh
make -f Makefile.cluster.nodbg  golden
```
## build test application

```sh
cd isolde/system
. ./eth.sh
make -f Makefile.cluster.nodbg  test-clean test-build
```
# verilator
```sh
cd isolde/system
. ./eth.sh
make -f Makefile.cluster.nodbg  veri-clean verilate veri-run
```

# QUESTA
```sh
cd isolde/system
. ./eth.sh
make -f Makefile.cluster.nodbg  questa-clean questa-run
```

## [REDMULE](https://github.com/ISOLDE-Project/redmule) hardware accelerator
Details about the accelerator are [here](https://github.com/ISOLDE-Project/redmule?tab=readme-ov-file#redmule)




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
# QUESTA
setup the environment
```sh
cd isolde/system
. ./qsim.sh
make TEST=hello_test test-clean test-build
```
## compile
```sh
make -f Makefile.cluster.nodbg  questa-compile
```
## lint
```sh
make -f Makefile.cluster.nodbg  questa-clean questa-lint
```
## headless simulation(with debug info)
```sh
make -f Makefile.cluster.nodbg  questa-run
```
## GUI simulation
```sh
make -f Makefile.cluster.nodbg  questa-qui
```
# QUESTA FAQ
```
fusesoc --cores-root=/icd/home/uidl7286/ibex-openeda run --target=sim --setup --no-export \
         --build-root=/icd/home/uidl7286/ibex-openeda/isolde/system/tmp/isolde \
        isolde:ibex:lca_dm_system 
Traceback (most recent call last):
  File "/home/uidl7286/miniconda3/envs/ibex/bin/fusesoc", line 7, in <module>
    sys.exit(main())
  File "/home/uidl7286/miniconda3/envs/ibex/lib/python3.10/site-packages/fusesoc/main.py", line 835, in main
    fusesoc(args)
  File "/home/uidl7286/miniconda3/envs/ibex/lib/python3.10/site-packages/fusesoc/main.py", line 825, in fusesoc
    args.func(cm, args)
  File "/home/uidl7286/miniconda3/envs/ibex/lib/python3.10/site-packages/fusesoc/main.py", line 401, in run
    run_backend(
  File "/home/uidl7286/miniconda3/envs/ibex/lib/python3.10/site-packages/fusesoc/main.py", line 476, in run_backend
    edalizer.run()
  File "/home/uidl7286/miniconda3/envs/ibex/lib/python3.10/site-packages/fusesoc/edalizer.py", line 83, in run
    self._prepare_work_root()
  File "/home/uidl7286/miniconda3/envs/ibex/lib/python3.10/site-packages/fusesoc/edalizer.py", line 127, in _prepare_work_root
    shutil.rmtree(os.path.join(self.work_root, f))
  File "/home/uidl7286/miniconda3/envs/ibex/lib/python3.10/shutil.py", line 725, in rmtree
    _rmtree_safe_fd(fd, path, onerror)
  File "/home/uidl7286/miniconda3/envs/ibex/lib/python3.10/shutil.py", line 664, in _rmtree_safe_fd
    onerror(os.rmdir, fullname, sys.exc_info())
  File "/home/uidl7286/miniconda3/envs/ibex/lib/python3.10/shutil.py", line 662, in _rmtree_safe_fd
    os.rmdir(entry.name, dir_fd=topfd)
OSError: [Errno 39] Directory not empty: 'lowrisc_prim_prim_pkg-impl_0.1'
```
unfortunatelly, kill all processes
```sh
killall -u <user_name>
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