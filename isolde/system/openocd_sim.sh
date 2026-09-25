#!/usr/bin/env bash

source ./eth.sh

"$OPENOCD" -f isolde.cfg -f ./jtag_upload.tcl
