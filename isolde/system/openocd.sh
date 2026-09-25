#!/usr/bin/env bash

source ./eth.sh

"$OPENOCD" -f ./fpga/openocd-zcu104-digilent-jtag-hs2.cfg -f ./jtag_upload.tcl
