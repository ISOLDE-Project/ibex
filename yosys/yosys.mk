# Copyright (c) 2022 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Authors:
# - Philippe Sauter <phsauter@iis.ee.ethz.ch>

# Tools
YOSYS    ?= yosys

# Directories
# directory of the path to the last called Makefile (this one)
YOSYS_DIR 		:= $(ROOT_DIR)/yosys
YOSYS_OUT		:= $(YOSYS_DIR)/out
YOSYS_TMP		:= $(YOSYS_DIR)/tmp
YOSYS_REPORTS	:= $(YOSYS_DIR)/reports

# top level to be synthesized
TOP_DESIGN		?= rv_top

# file containing include dirs, defines and paths to all source files
SV_FLIST    	:= $(YOSYS_DIR)/../yosys.flist
$(SV_FLIST): yosys-flist

# path to the resulting netlists (debug preserves multibit signals)
NETLIST			:= $(YOSYS_OUT)/$(TOP_DESIGN)_yosys.v
NETLIST_DEBUG	:= $(YOSYS_OUT)/$(TOP_DESIGN)_debug_yosys.v

FLOW_SRC ?= $(YOSYS_DIR)/scripts/yosys_synthesis.tcl 

ifneq ($(strip $(FLOW)),)

# If FLOW already ends with .tcl → use as-is
	ifneq ($(filter %.tcl,$(FLOW)),)
		FLOW_SRC = $(YOSYS_DIR)/scripts/$(FLOW)

# Otherwise append .tcl
	else
		FLOW_SRC = $(YOSYS_DIR)/scripts/$(FLOW).tcl
	endif

endif

## Synthesize netlist using Yosys, make [FLOW=<flow_name>|<flow_name.tcl>]
yosys: $(NETLIST)

$(NETLIST) $(NETLIST_DEBUG):  $(SV_FLIST)
	@mkdir -p $(YOSYS_OUT)
	@mkdir -p $(YOSYS_TMP)
	@mkdir -p $(YOSYS_REPORTS)
	cd $(YOSYS_DIR) && \
	SV_FLIST="$(SV_FLIST)" \
	TOP_DESIGN="$(TOP_DESIGN)" \
	TMP="$(YOSYS_TMP)" \
	OUT="$(YOSYS_OUT)" \
	REPORTS="$(YOSYS_REPORTS)" \
	$(YOSYS) -c $(FLOW_SRC) \
		2>&1 | TZ=UTC gawk '{ print strftime("[%Y-%m-%d %H:%M %Z]"), $$0 }' \
		     | tee "$(YOSYS_DIR)/$(TOP_DESIGN).log" \
		     | gawk -f $(YOSYS_DIR)/scripts/filter_output.awk;
		




yosys-clean:
	rm -rf $(YOSYS_OUT)
	rm -rf $(YOSYS_TMP)
	rm -rf $(YOSYS_REPORTS) 
	rm -f $(YOSYS_DIR)/*.log
	rm -f $(SV_FLIST)
	rm -f $(SYS_DIR)/ibex_synth.tcl
	rm -f $(SYS_DIR)/yosys-manifest.flist
## Show available flows	
show-flows:
	@echo "Available flows:"
#	@ls $(YOSYS_DIR)/scripts/*.tcl | xargs -n 1 basename | sed 's/\.tcl$$//'
	@echo "yosys_synthesis (default)"
	@echo "yosys_check"

sv-wrapper:
	python3 $(YOSYS_DIR)/scripts/make_wrapper.py $(NETLIST) $(YOSYS_OUT)/$(TOP_DESIGN).sv

.PHONY:  yosys	yosys-check yosys-clean show-flows sv-wrapper
