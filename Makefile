ROOT_DIR            :=  $(shell git rev-parse --show-toplevel)
SYS_DIR             := $(ROOT_DIR)/isolde/system


# Tools
BENDER	  ?= bender
PYTHON3   ?= python3
YOSYS     ?= yosys
OPENROAD  ?= openroad
KLAYOUT   ?= klayout
VSIM      ?= vsim


####################
# Open Source Flow #
####################
# Bender manages the different IPs and can be used to generate file-lists for synthesis
# TOP_DESIGN     ?= croc_chip
# DUT_DESIGN	   ?= croc_soc
# BENDER_TARGETS ?= asic ihp13 rtl synthesis
# SV_DEFINES     ?= VERILATOR SYNTHESIS COMMON_CELLS_ASSERTS_OFF



## Generate yosys.flist used to read design in yosys
yosys-flist:  
	make -C $(SYS_DIR) vivado-clean  ibex_synth.tcl
	tclsh $(ROOT_DIR)/yosys/scripts/vivado_tcl_to_yosys_f.tcl $(SYS_DIR)/ibex_synth.tcl
	make -C $(SYS_DIR) DBG_MODULE=1 \
	                   ENABLE_SPM=1 \
					   BENDER_EXTRA_TARGET="-t yosys" \
					   yosys-manifest.flist
	cat  ibex-yosys.flist $(SYS_DIR)/yosys-manifest.flist >$(ROOT_DIR)/yosys.flist


include yosys/yosys.mk
include openroad/openroad.mk

###########
# Cleanup #
###########

## Delete generated files and directories
clean: 
	$(MAKE) yosys-clean
	rm -f $(SYS_DIR)/ibex_synth.tcl
	rm -f $(SYS_DIR)/yosys-manifest.flist
	rm -f yosys.flist

.PHONY: clean

.PHONY: redmule-clean
redmule-clean:
	cd vendor/redmule && \
	git reset --hard  && \
	git clean -xfdxf

## Delete bender generated file
bender-clean:
	rm -f $(SYS_DIR)/Bender.lock

## Checkout/update dependencies using Bender
checkout: $(IHP_RCX_FILE)
	git submodule update --init --recursive 
	cd isolde/system/ && \
	$(BENDER) checkout && \
	make -C patches 
	

.PHONY: bender-clean checkout

include common.mk
