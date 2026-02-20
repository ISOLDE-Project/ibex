###############################################################################
#
# Copyleft  2024 ISOLDE
#

#############
# Verilator #
#############

#####
VERI_LOG_DIR      ?= $(mkfile_path)/log/$(VLT_TOP_MODULE)/$(IMEM_LATENCY)
BIN_DIR           = $(mkfile_path)/bin/$(VLT_TOP_MODULE)/$(IMEM_LATENCY)
VERI_FLAGS        +=
NO_TEE		      ?= 1
#####
ifeq ($(NO_TEE),1)
  TEE_CMD := 
else
  TEE_CMD := | tee $(VERI_LOG_DIR)/$(TEST).log
endif



.PHONY: veri-clean 

# Clean all build directories and temporary files for verilator simulation
veri-clean: 
	rm -f *.flist
	rm -fr log/$(VLT_TOP_MODULE) 
	make -C sim/core -f Makefile.verilator  	 SIM_RESULTS=$(BIN_DIR)                  \
												   RUN_INDEX=$(IMEM_LATENCY)           \
											  VLT_TOP_MODULE=$(VLT_TOP_MODULE)           \
									   VLT_TOP_MODULE_PARAMS=$(VLT_TOP_MODULE_PARAMS)    \
									 $@
	rm -fr $(FUSESOC_BUILD_ROOT) 


##
CORE_FILES := $(filter %.core,$(wildcard $(mkfile_path)/*))
CORE_FILES += $(filter %.core,$(wildcard $(ROOT_DIR)/*))
CORE_FILE_NAMES := $(notdir $(CORE_FILES))

ibex_sim.flist:  $(CORE_FILES)
	@echo $(CORE_FILE_NAMES)
	fusesoc --cores-root=$(ROOT_DIR) run --target=sim --setup --no-export $(FUSESOC_PARAMS)  --build-root=$(FUSESOC_BUILD_ROOT) $(FUSESOC_PKG_NAME) $(FUSESOC_CONFIG_OPTS) 
	python $(ROOT_DIR)/util/transform_paths.py  \
										       $(FUSESOC_BUILD_ROOT)/sim-verilator  \
	                                           $(FUSESOC_BUILD_ROOT)/sim-verilator/$(FUSESOC_PROJECT)_$(FUSESOC_CORE)_$(FUSESOC_SYSTEM)_0.vc \
											   $@
	python $(ROOT_DIR)/util/verilator_manifest.py  Verilator.yml \
											    -t  $(verilator_target)       \
											    -o $@	
	touch $@
##

manifest.flist: Bender.yml
	$(BENDER) script verilator $(common_targs) $(BENDER_EXTRA_TARGET) $(VLT_BENDER)  >$@
	touch $@


verilate:  ibex_sim.flist manifest.flist
#	mkdir -p $(dir $@)
	mkdir -p $(BIN_DIR)
	make -C sim/core -f Makefile.verilator CV_CORE_MANIFEST=${CURDIR}/ibex_sim.flist     \
											     PE_MANIFEST=${CURDIR}/manifest.flist    \
	                                             SIM_RESULTS=$(BIN_DIR)                  \
												   RUN_INDEX=$(IMEM_LATENCY)           \
											  VLT_TOP_MODULE=$(VLT_TOP_MODULE)           \
									   VLT_TOP_MODULE_PARAMS=$(VLT_TOP_MODULE_PARAMS)    \
											  verilate      


veri-lint:  ibex_sim.flist manifest.flist
	make -C sim/core -f Makefile.verilator CV_CORE_MANIFEST=${CURDIR}/ibex_sim.flist     \
											     PE_MANIFEST=${CURDIR}/manifest.flist    \
	                                             SIM_RESULTS=$(BIN_DIR)                  \
												   RUN_INDEX=$(IMEM_LATENCY)           \
											  VLT_TOP_MODULE=$(VLT_TOP_MODULE)           \
									   VLT_TOP_MODULE_PARAMS=$(VLT_TOP_MODULE_PARAMS)    \
									   $@      

.PHONY: veri-run
veri-run: $(BIN_DIR)/verilator_executable 
	@echo "$(BANNER)"
	@echo "* Running with Verilator: "
	@echo "*                            logfile: $(VERI_LOG_DIR)/$(TEST).log"
	@echo "*                    rtl debug trace: $(VERI_LOG_DIR)/rtl_debug_trace.log"
	@echo "*                              *.vcd: $(VERI_LOG_DIR)"
	@echo "$(BANNER)"
	# === Create/clean-up destination log folder ===
	mkdir -p $(VERI_LOG_DIR)
	rm -f $(VERI_LOG_DIR)/*
	@echo "TEE_CMD=$(TEE_CMD)"

	# === Check for required input files ===
	@if [ ! -f "$(test-program)-m.hex" ]; then \
		echo "ERROR: Missing file: $(test-program)-m.hex"; \
		exit 1; \
	fi
	@if [ ! -f "$(test-program)-d.hex" ]; then \
		echo "ERROR: Missing file: $(test-program)-d.hex"; \
		exit 1; \
	fi

	$(BIN_DIR)/verilator_executable  \
		$(VERI_FLAGS) \
		"+STIM_INSTR=$(test-program)-m.hex" \
		"+STIM_DATA=$(test-program)-d.hex" \
		$(TEE_CMD)

	# === Check for expected output files ===
	@if [ ! -f "verilator_tb.vcd" ]; then \
		echo "ERROR: Output file missing: verilator_tb.vcd"; \
		exit 1; \
	fi
	@if [ ! -f "rtl_debug_trace.log" ]; then \
		echo "ERROR: Output file missing: rtl_debug_trace.log"; \
		exit 1; \
	fi

	mv verilator_tb.vcd $(VERI_LOG_DIR)/$(TEST).vcd
	mv rtl_debug_trace.log $(VERI_LOG_DIR)

	@if [  -f "perfcnt.csv" ]; then \
		mv perfcnt.csv $(VERI_LOG_DIR)/$(TEST).csv; \
	fi

	

.PHONY: veri-run-u-test
veri-run-u-test: $(BIN_DIR)/verilator_executable 
	@echo "$(BANNER)"
	@echo "* Running with Verilator: "
	@echo "*                            logfile: $(VERI_LOG_DIR)/$(TEST).log"
	@echo "*                    rtl debug trace: $(VERI_LOG_DIR)/rtl_debug_trace.log"
	@echo "*                              *.vcd: $(VERI_LOG_DIR)"
	@echo "$(shell pwd)"
	mkdir -p $(VERI_LOG_DIR)
	rm -f $(VERI_LOG_DIR)/verilator_tb.vcd
	$(BIN_DIR)/verilator_executable  \
		| tee $(VERI_LOG_DIR)/$(VLT_TOP_MODULE).log
	mv verilator_tb.vcd $(VERI_LOG_DIR)/$(VLT_TOP_MODULE).vcd
	


.PHONY: help
help:
	@echo "verilator related available targets:"
	@echo verilate                                 -- builds verilator simulation, available here: $(BIN_DIR)/verilator_executable
	@echo veri-run                                 -- runs the test
	@echo veri-clean                               -- gets a clean slate for simulation
	@echo verilate VLT_TOP_MODULE=tb_top_verilator
	

.PHONY: bender-clean
bender-clean:
	@echo "Cleaning Bender project..."
	rm -rf .bender
	rm -rf  Bender.lock
	@echo "Bender project cleaned."

.PHONY: rtl-update
rtl-update:	bender-clean
	git submodule update --init
	bender update