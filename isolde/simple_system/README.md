# Tests
build the hw simulation
```sh
make verilate
```
## dhrystone
**dhrystone** is the default test application
```sh
make veri-run
```
Expected output: see [ibex_simple_system.log](ibex_simple_system.log)
**Note**: make sure that you have the remote version of *ibex_simple_system.log* in the working tree( this file is overwritten upon each simulation execution)
## Fibonacci

```sh
make TEST=fibonacci  veri-run
```
Expected output
```
Performance Counters
====================
Cycles:               46989
Instructions Retired: 30029

ibex_simple_system.log
======================
starting fib(15)...
fib(0) = 0
fib(1) = 1
fib(2) = 1
fib(3) = 2
fib(4) = 3
fib(5) = 5
fib(6) = 8
fib(7) = 13
fib(8) = 21
fib(9) = 34
fib(10) = 55
fib(11) = 89
fib(12) = 144
fib(13) = 233
fib(14) = 377
finishing...
exit()
======
======================
isolde_exec_block.log

```