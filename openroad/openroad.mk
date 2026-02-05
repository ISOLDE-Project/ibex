# Copyright 2023 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
#
# Authors:
# - Philippe Sauter <phsauter@iis.ee.ethz.ch>

# Tools
OPENROAD 		?= openroad

# Directories
# directory of the path to the last called Makefile (this one)
OR_DIR    := $(realpath $(dir $(realpath $(lastword $(MAKEFILE_LIST)))))

# Project variables
# if you are running the entire flow these are set by the top level Makefile
# in that case do not change them here
TOP_DESIGN  ?= rv_top
PROJ_NAME	?= $(TOP_DESIGN)
NETLIST		?= $(realpath $(OR_DIR)/../yosys/out/$(PROJ_NAME)_yosys.v)

SAVE	 	 ?= $(OR_DIR)/save
REPORTS	 	 ?= $(OR_DIR)/reports
OR_OUT  	 ?= $(OR_DIR)/out
OR_OUT_FILES  = $(OR_OUT)/$(PROJ_NAME).def $(OR_OUT)/$(PROJ_NAME).v $(OR_OUT)/$(PROJ_NAME).sdc $(OR_OUT)/$(PROJ_NAME).odb

################
# Dependencies #
################
# Download RCX file used for parasitic extraction from ORFS (configuration got ok by IHP)
IHP_RCX_URL  := "https://raw.githubusercontent.com/The-OpenROAD-Project/OpenROAD-flow-scripts/7747f88f70daaeb63f43ce36e71829707b7e3fa7/flow/platforms/ihp-sg13g2/IHP_rcx_patterns.rules"
IHP_RCX_FILE := $(ROOT_DIR)/openroad/IHP_rcx_patterns.rules


$(IHP_RCX_FILE): 
	curl -L -o $@ $(IHP_RCX_URL)
	touch $@


backend: $(OR_OUT)/$(PROJ_NAME).def

openroad: $(OR_OUT)/$(PROJ_NAME).def

## Place & Route flow using OpenROAD
$(OR_OUT_FILES): $(NETLIST) $(OR_DIR)/scripts/*.tcl $(OR_DIR)/src/*.tcl $(OR_DIR)/src/*.sdc $(IHP_RCX_FILE)
	mkdir -p $(SAVE)
	mkdir -p $(REPORTS)
	mkdir -p $(OR_OUT)
	cd $(OR_DIR) && \
	NETLIST="$(NETLIST)" \
	TOP_DESIGN="$(TOP_DESIGN)" \
	PROJ_NAME="$(PROJ_NAME)" \
	SAVE="$(SAVE)" \
	REPORTS="$(REPORTS)" \
	QT_QPA_PLATFORM=$$(if [ -z "$$DISPLAY" ]; then echo "offscreen"; else echo "$$QT_QPA_PLATFORM"; fi) \
	$(OPENROAD) scripts/chip.tcl \
		$$(if [ "$(gui)" = "1" ]; then echo "-gui"; fi) \
		-log $(PROJ_NAME).log \
		2>&1 | TZ=UTC gawk '{ print strftime("[%Y-%m-%d %H:%M %Z]"), $$0 }';

openroad-clean:
	rm -rf $(SAVE)
	rm -rf $(REPORTS)
	rm -rf $(OR_OUT)
	rm -f $(OR_DIR)/$(PROJ_NAME).log
	rm -f $(OR_DIR)/*.rules

start_openroad:
	cd $(OR_DIR) && \
	PROJ_NAME="$(PROJ_NAME)" \
	SAVE="$(SAVE)" \
	REPORTS="$(REPORTS)" \
	$(OPENROAD) scripts/startup.tcl

start_openroad_gui:
	cd $(OR_DIR) && \
	PROJ_NAME="$(PROJ_NAME)" \
	SAVE="$(SAVE)" \
	REPORTS="$(REPORTS)" \
	$(OPENROAD) -gui scripts/startup.tcl

.PHONY: backend openroad openroad-clean start_openroad start_openroad_gui

generate-pins: 
	python3 $(OR_DIR)/scripts/generate_pins.py -o $(OR_DIR)/src/pin_placement.tcl $(NETLIST) 