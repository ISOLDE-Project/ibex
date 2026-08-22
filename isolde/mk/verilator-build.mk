###############################################################################
#
# Copyleft  2024 ISOLDE
#

# FUSESOC_IGNORE 
TASK52_DIR            := $(ROOT_DIR)/.task5.2
FUSESOC_IGNORE_FILE   := $(TASK52_DIR)/FUSESOC_IGNORE
#############
# Verilator #
#############

#####
VERI_LOG_DIR      ?= $(mkfile_path)/log/$(VLT_TOP_MODULE)/$(IMEM_LATENCY)
SIM_TEST_INPUTS   ?= $(mkfile_path)/vsim
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

# FUSESOC_STRACE_LOG ?= $(mkfile_path)/fusesoc_openat.strace

# Prevent FuseSoC from recursively scanning .task5.2.
#
# mkdir -p makes this safe even if .task5.2 has not been created yet.
$(FUSESOC_IGNORE_FILE):
	@mkdir -p $(dir $@)
	@touch $@
	@echo "Created FuseSoC ignore marker: $@"


ibex_sim.flist:  $(CORE_FILES) $(FUSESOC_IGNORE_FILE)
	@touch $(TASK52_DIR)/FUSESOC_IGNORE 
	@echo $(CORE_FILE_NAMES)
	fusesoc --cores-root=$(ROOT_DIR) run --target=sim --setup --no-export $(FUSESOC_PARAMS)  --build-root=$(FUSESOC_BUILD_ROOT) $(FUSESOC_PKG_NAME) $(FUSESOC_CONFIG_OPTS) 
# 	@rm -f "$(FUSESOC_STRACE_LOG)"
# 	@echo "Tracing FuseSoC file accesses to: $(FUSESOC_STRACE_LOG)"
# 	@set +e; \
# 	strace -f \
# 		-e trace=openat \
# 		-o "$(FUSESOC_STRACE_LOG)" \
# 		fusesoc \
# 			--cores-root=$(ROOT_DIR) \
# 			run \
# 			--target=sim \
# 			--setup \
# 			--no-export \
# 			$(FUSESOC_PARAMS) \
# 			--build-root=$(FUSESOC_BUILD_ROOT) \
# 			$(FUSESOC_PKG_NAME) \
# 			$(FUSESOC_CONFIG_OPTS); \
# 	status=$$?; \
# 	if [ $$status -ne 0 ]; then \
# 		echo ""; \
# 		echo "============================================================"; \
# 		echo "FuseSoC failed with exit status $$status"; \
# 		echo "Last .core files opened by FuseSoC:"; \
# 		echo "============================================================"; \
# 		grep '\.core' "$(FUSESOC_STRACE_LOG)" | tail -30 || true; \
# 		echo "============================================================"; \
# 		echo "Full strace log: $(FUSESOC_STRACE_LOG)"; \
# 		echo "============================================================"; \
# 		exit $$status; \
# 	fi
	python $(ROOT_DIR)/util/transform_paths.py  \
										       $(FUSESOC_BUILD_ROOT)/sim-verilator  \
	                                           $(FUSESOC_BUILD_ROOT)/sim-verilator/$(FUSESOC_PROJECT)_$(FUSESOC_CORE)_$(FUSESOC_SYSTEM)_0.vc \
											   $@
	touch $@
##

manifest.flist: Bender.yml
	$(BENDER) script verilator $(common_targs) $(BENDER_EXTRA_TARGET) $(VLT_BENDER)  >$@
	touch $@

VERILATE_LOG      := $(VERI_LOG_DIR)/verilate.log
VERILATE_WARNINGS := $(VERI_LOG_DIR)/verilate_warnings.log

## build the simulation
# verilate:  ibex_sim.flist manifest.flist
verilate:  $(VLT_TOP_MODULE)_all_deps.f
	mkdir -p  $(VERI_LOG_DIR)
	cat ibex_sim.slang_veri_opts manifest.slang_veri_opts> ops.verilator.flist
	python $(ROOT_DIR)/util/transform_paths.py  \
										       $(mkfile_path)  \
	                                           $(VLT_TOP_MODULE)_all_deps.f \
											   manifest.verilator.flist
	python $(ROOT_DIR)/util/verilator_manifest.py  Verilator.yml \
											    -t  $(verilator_target)    \
											    -o  manifest.verilator.flist	
	mkdir -p $(BIN_DIR)
	make -C sim/core -f Makefile.verilator CV_CORE_MANIFEST=${CURDIR}/ops.verilator.flist     \
											     PE_MANIFEST=${CURDIR}/manifest.verilator.flist    \
	                                             SIM_RESULTS=$(BIN_DIR)                  \
												   RUN_INDEX=$(IMEM_LATENCY)           \
											  VLT_TOP_MODULE=$(VLT_TOP_MODULE)           \
									   VLT_TOP_MODULE_PARAMS=$(VLT_TOP_MODULE_PARAMS)    \
											  verilate      2>&1 | \
	tee "$(VERILATE_LOG)" | \
	gawk -v warnings_file="$(VERILATE_WARNINGS)" -f "$(SCRIPTS_DIR)/questa.awk"


veri-lint:  ibex_sim.flist manifest.flist
	make -C sim/core -f Makefile.verilator CV_CORE_MANIFEST=${CURDIR}/ibex_sim.flist     \
											     PE_MANIFEST=${CURDIR}/manifest.flist    \
	                                             SIM_RESULTS=$(BIN_DIR)                  \
												   RUN_INDEX=$(IMEM_LATENCY)           \
											  VLT_TOP_MODULE=$(VLT_TOP_MODULE)           \
									   VLT_TOP_MODULE_PARAMS=$(VLT_TOP_MODULE_PARAMS)    \
									   $@      
## run the verilator simulation
.PHONY: veri-run
veri-run: $(BIN_DIR)/verilator_executable 
	@echo "$(BANNER)"
	@echo "* Running with Verilator: "
	@echo "*                            logfile: $(VERI_LOG_DIR)/$(TEST).log"
	@echo "*                    rtl debug trace: $(VERI_LOG_DIR)/trace_core_00000000.log"
	@echo "*                              *.vcd: $(VERI_LOG_DIR)/$(TEST).vcd"
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
		echo "⚠️  CRITICAL WARNING: Output file missing: verilator_tb.vcd"; \
		else \
		mv verilator_tb.vcd $(VERI_LOG_DIR)/$(TEST).vcd; \
	fi

	@if [ ! -f "trace_core_00000000.log" ]; then \
		echo "⚠️  CRITICAL WARNING: Output file missing: trace_core_00000000.log"; \
		else \
		mv trace_core_00000000.log $(VERI_LOG_DIR); \
	fi


	@if [  -f "perfcnt.csv" ]; then \
		mv perfcnt.csv $(VERI_LOG_DIR)/$(TEST).csv; \
		echo "🔔               performance counters: $(VERI_LOG_DIR)/$(TEST).csv";\
	fi

	

.PHONY: veri-run-u-test
veri-run-u-test: $(BIN_DIR)/verilator_executable 
	@echo "$(BANNER)"
	@echo "* Running with Verilator: "
	@echo "*                            logfile: $(VERI_LOG_DIR)/$(TEST).log"
	@echo "*                    rtl debug trace: $(VERI_LOG_DIR)/trace_core_00000000.log"
	@echo "*                              *.vcd: $(VERI_LOG_DIR)"
	@echo "$(shell pwd)"
	mkdir -p $(VERI_LOG_DIR)
	rm -f $(VERI_LOG_DIR)/verilator_tb.vcd
	$(BIN_DIR)/verilator_executable  \
		| tee $(VERI_LOG_DIR)/$(VLT_TOP_MODULE).log
	mv verilator_tb.vcd $(VERI_LOG_DIR)/$(VLT_TOP_MODULE).vcd
	

	

