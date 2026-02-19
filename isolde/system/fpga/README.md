# Vivado
in folder *isolde/system/fpga*:
```sh
make help
```
## Full project
```sh
make clean clean-vivado impl
```
## No SPM(no hardware accelerators)
```sh
make -f Makefile.nospm  clean clean-vivado impl
```

# UART JTAG test

```sh
hexdump -v -e '1/1 "%02X "' /dev/ttyUSB3
```
```sh
minicom -D /dev/ttyUSB3 -b 115200
```