# Vivado project
in folder *isolde/system/fpga*:
```sh
make -f Makefile.nospm clean-vivado impl
```

# UART JTAG test

```sh
hexdump -v -e '1/1 "%02X "' /dev/ttyUSB3
```
```sh
minicom -D /dev/ttyUSB3 -b 115200
```