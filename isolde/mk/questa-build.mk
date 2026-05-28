###############################################################################
#
# Copyleft  2024 ISOLDE
#

############
# QuestaSim #
############
# QUESTA_TOP_MODULE ?= $(VLT_TOP_MODULE)
QUESTA_TOP_MODULE := tb_top_questa
QUESTA_LOG_DIR    ?= $(mkfile_path)/log/$(QUESTA_TOP_MODULE)/$(IMEM_LATENCY)
BIN_DIR            = $(mkfile_path)/bin/$(QUESTA_TOP_MODULE)/$(IMEM_LATENCY)
QUESTA_FLAGS      += 
NO_TEE            ?= 1

# Work library location
WORK_LIB           = $(BIN_DIR)/work

# qrun binary (override if not on PATH)
QRUN              ?= qrun
#####

ifeq ($(NO_TEE),1)
  TEE_CMD :=
else
  TEE_CMD := | tee $(QUESTA_LOG_DIR)/$(TEST).log
endif


# .PHONY: questa-clean

# # Clean all build directories and temporary files for QuestaSim simulation
questa-clean:
	rm -f ibex_questa.flist manifest_questa.flist
	rm -fr $(BIN_DIR)
	rm -fr $(QUESTA_LOG_DIR)
	rm -fr tmp/*

# 	rm -fr log/$(QUESTA_TOP_MODULE)



##
CORE_FILES      := $(filter %.core,$(wildcard $(mkfile_path)/*))
CORE_FILES      += $(filter %.core,$(wildcard $(ROOT_DIR)/*))
CORE_FILE_NAMES := $(notdir $(CORE_FILES))

ibex_questa.flist: $(CORE_FILES)
	@echo $(CORE_FILE_NAMES)
	fusesoc --cores-root=$(ROOT_DIR) run --target=sim --setup --no-export \
	        $(FUSESOC_PARAMS) --build-root=$(FUSESOC_BUILD_ROOT)          \
	        $(FUSESOC_PKG_NAME) $(FUSESOC_CONFIG_OPTS)
# 	# Transform paths for QuestaSim (questa subtree instead of sim-verilator)
	python $(ROOT_DIR)/util/flist2questa.py                            \
	        $(FUSESOC_BUILD_ROOT)/sim-verilator/$(FUSESOC_PROJECT)_$(FUSESOC_CORE)_$(FUSESOC_SYSTEM)_0.vc \
	        $@                              \
			--anchor $(FUSESOC_BUILD_ROOT)/sim-verilator
	touch $@
##

BENDER_ARGS  :=  script verilator $(common_targs) $(BENDER_EXTRA_TARGET) $(QUESTA_BENDER)
manifest_questa.flist: Bender.yml
	@echo 'INFO:  $(BENDER_ARGS)'
	@$(BENDER) $(BENDER_ARGS) > $@_tmp
	python $(ROOT_DIR)/util/verilator_manifest.py  Verilator.yml \
											    -t   questa      \
											    -o $@_tmp	
	python $(ROOT_DIR)/util/flist2questa.py                            \
		 $@_tmp \
		$@                              \
		--anchor $(mkfile_path)
	touch $@


# ---------------------------------------------------------------------------
# questa-compile: analyze + elaborate all RTL sources into the work library.
# ---------------------------------------------------------------------------

QUESTA_SUPPRESS  = -suppress 2244
QUESTA_SUPPRESS += -suppress 442  # Port not found in module 
QUESTA_SUPPRESS += -suppress 2912  # Port not found in module 
QUESTA_SUPPRESS += -suppress 1882  # 
QUESTA_SUPPRESS += -suppress 7063  # 
QUESTA_SUPPRESS += -suppress 7045  #  driven by more than one continuous assignment
#QUESTA_SUPPRESS += -suppress 7061  # Variable  driven in an always_ff block, may not be driven by any other process.
#QUESTA_SUPPRESS += -suppress 79000
#QUESTA_SUPPRESS += -suppress 63000

# Disable assertions globally in all qrun invocations
QUESTA_NO_ASSERT := 

.PHONY: questa-compile
questa-compile: ibex_questa.flist manifest_questa.flist
	mkdir -p $(BIN_DIR)
	$(QRUN)   -f ibex_questa.flist                                          \
	          -f manifest_questa.flist                                          \
	          -work $(WORK_LIB)                                          \
	          -top  $(QUESTA_TOP_MODULE)$(QUESTA_TOP_MODULE_PARAMS)      \
	          -compile                                                   \
			  $(QUESTA_SUPPRESS)                                         \
			  $(QUESTA_NO_ASSERT)                                      \
	          -64                                                        \
	          -sv                                                        \
	          -outdir $(BIN_DIR)


questa-lint: ibex_questa.flist manifest_questa.flist
	$(QRUN)   -f ibex_questa.flist                                          \
	          -f manifest_questa.flist                                   \
	          -work $(WORK_LIB)                                          \
	          -top  $(QUESTA_TOP_MODULE)$(QUESTA_TOP_MODULE_PARAMS)      \
	          -compile                                                   \
			  $(QUESTA_SUPPRESS)                                         \
	          -lint                                                      \
	          -64                                                        \
	          -sv                                                        


# ---------------------------------------------------------------------------
# questa-run: simulate the compiled design.
# Replaces veri-run; plusargs and VCD output are preserved.
# ---------------------------------------------------------------------------
.PHONY: questa-run
questa-run: ibex_questa.flist manifest_questa.flist
	@echo "$(BANNER)"
	@echo "* Running with QuestaSim:"
	@echo "*                            logfile: $(QUESTA_LOG_DIR)/$(TEST).log"
	@echo "*                    rtl debug trace: $(QUESTA_LOG_DIR)/rtl_debug_trace.log"
	@echo "*                              *.vcd: $(QUESTA_LOG_DIR)"
	@echo "$(BANNER)"

	# === Create/clean-up destination log folder ===
	mkdir -p $(QUESTA_LOG_DIR)
	rm -f $(QUESTA_LOG_DIR)/*

	# === Check for required input files ===
	@if [ ! -f "$(test-program)-m.hex" ]; then \
		echo "ERROR: Missing file: $(test-program)-m.hex"; \
		exit 1; \
	fi
	@if [ ! -f "$(test-program)-d.hex" ]; then \
		echo "ERROR: Missing file: $(test-program)-d.hex"; \
		exit 1; \
	fi

	# === Launch simulation ===
	# -do inline script: enable VCD dump, run to completion, quit.
	$(QRUN)  -f ibex_questa.flist                      \
	         -f manifest_questa.flist                  \
	         -work   $(WORK_LIB)                       \
	         -top    $(QUESTA_TOP_MODULE)               \
	         -64 -sv                            \
	         -outdir $(BIN_DIR)                        \
	         -logfile $(QUESTA_LOG_DIR)/$(TEST).log    \
	         $(QUESTA_SUPPRESS)                        \
			 $(QUESTA_NO_ASSERT)                                      \
	         $(QUESTA_FLAGS)                           \
	         +STIM_INSTR=$(test-program)-m.hex         \
	         +STIM_DATA=$(test-program)-d.hex          \
	         -do "vcd file questa_tb.vcd;              \
	              vcd add -r /*;                       \
				  set assertion -disable -all;         \
	              run -all;                            \
	              quit -f"                                    

	# === Check for expected output files ===
	@if [ ! -f "questa_tb.vcd" ]; then \
		echo "ERROR: Output file missing: questa_tb.vcd"; \
		exit 1; \
	fi

	@if [ ! -f "rtl_debug_trace.log" ]; then \
		echo "⚠️  CRITICAL WARNING: Output file missing: rtl_debug_trace.log"; \
		else \
		mv rtl_debug_trace.log $(QUESTA_LOG_DIR); \
	fi	

	mv questa_tb.vcd   $(QUESTA_LOG_DIR)/$(TEST).vcd
	
	@if [ -f "perfcnt.csv" ]; then \
		mv perfcnt.csv $(QUESTA_LOG_DIR)/$(TEST).csv; \
	fi


# ---------------------------------------------------------------------------
# questa-run-u-test: headless unit-test run (no hex file guards).
# Replaces veri-run-u-test.
# ---------------------------------------------------------------------------
.PHONY: questa-run-u-test
questa-run-u-test: questa-compile
	@echo "$(BANNER)"
	@echo "* Running with QuestaSim (unit test):"
	@echo "*                            logfile: $(QUESTA_LOG_DIR)/$(QUESTA_TOP_MODULE).log"
	@echo "*                              *.vcd: $(QUESTA_LOG_DIR)"
	@echo "$(shell pwd)"
	mkdir -p $(QUESTA_LOG_DIR)
	rm -f $(QUESTA_LOG_DIR)/questa_tb.vcd
	$(QRUN)   -work $(WORK_LIB)                                          \
	          -top  $(QUESTA_TOP_MODULE)                                 \
	          -simulate                                                  \
	          -64                                                        \
	          -outdir $(BIN_DIR)                                         \
	          -do "vcd file questa_tb.vcd;                               \
	               vcd add -r /*;                                        \
	               run -all;                                             \
	               quit -f"                                             \
	          | tee $(QUESTA_LOG_DIR)/$(QUESTA_TOP_MODULE).log
	mv questa_tb.vcd $(QUESTA_LOG_DIR)/$(QUESTA_TOP_MODULE).vcd





