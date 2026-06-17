###############################################################################
#
# Copyleft  2024 ISOLDE
#
###############################################################################

############
# QuestaSim #
############

# QUESTA_TOP_MODULE ?= $(VLT_TOP_MODULE)
QUESTA_TOP_MODULE      := tb_top_questa
QUESTA_BENDER          += $(VLT_BENDER)
QUESTA_LOG_DIR         ?= $(mkfile_path)/log/$(QUESTA_TOP_MODULE)/$(IMEM_LATENCY)
BIN_DIR                ?= $(mkfile_path)/bin/$(QUESTA_TOP_MODULE)/$(IMEM_LATENCY)

# qrun binary (override if not on PATH)
QRUN                   ?= qrun
NO_TEE                 ?= 1

# Work library location
WORK_LIB               := $(BIN_DIR)/work

# Optional extra user flags
QUESTA_FLAGS           += -timescale 1ns/1ps


# Warning suppressions
QUESTA_SUPPRESS        := -suppress 2244
QUESTA_SUPPRESS        += -suppress 442    # Port not found in module
QUESTA_SUPPRESS        += -suppress 2912   # Port not found in module
QUESTA_SUPPRESS        += -suppress 1882
QUESTA_SUPPRESS        += -suppress 7063
QUESTA_SUPPRESS        += -suppress 7045   # driven by more than one continuous assignment
# QUESTA_SUPPRESS      += -suppress 7061   # Variable driven in always_ff and elsewhere
# QUESTA_SUPPRESS      += -suppress 79000
# QUESTA_SUPPRESS      += -suppress 63000

# Disable assertions globally in all qrun invocations (ibex prim_assert flow)
QUESTA_NO_ASSERT       := +define+VERILATOR

# Tee handling
ifeq ($(NO_TEE),1)
  TEE_CMD :=
else
  TEE_CMD := | tee
endif

# Shared qrun args
QUESTA_COMMON_FFILES   := -f ibex_questa.flist -f manifest_questa.flist
QUESTA_COMMON_ARGS     := $(QUESTA_COMMON_FFILES)            \
                          -work $(WORK_LIB)                  \
                          -top $(QUESTA_TOP_MODULE)$(QUESTA_TOP_MODULE_PARAMS) \
                          -64 -sv                            \
                          -outdir $(BIN_DIR)                 \
                          $(QUESTA_SUPPRESS)                 \
                          $(QUESTA_NO_ASSERT)                \
                          $(QUESTA_FLAGS)                    

.PHONY: questa-clean questa-compile questa-lint questa-run questa-gui questa-run-u-test
.DELETE_ON_ERROR:

# ---------------------------------------------------------------------------
# Clean all build directories and temporary files for QuestaSim simulation
# ---------------------------------------------------------------------------
questa-clean:
	rm -f ibex_questa.flist manifest_questa.flist
	rm -rf $(BIN_DIR)
	rm -rf $(QUESTA_LOG_DIR)
# 	rm -rf tmp
# 	mkdir -p tmp

# ---------------------------------------------------------------------------
# Generate flists
# ---------------------------------------------------------------------------


ibex_questa.flist: ibex_sim.flist
	python $(ROOT_DIR)/util/flist2questa.py \
	        ibex_sim.flist \
	        $@ 



manifest_questa.flist: manifest.flist
	cat manifest.flist	 > $@_tmp
	python $(ROOT_DIR)/util/verilator_manifest.py Verilator.yml \
	        -t questa \
	        -o $@_tmp
	python $(ROOT_DIR)/util/flist2questa.py \
	        $@_tmp \
	        $@ 
	rm -f $@_tmp

# ---------------------------------------------------------------------------
# Analyze + elaborate all RTL sources into the work library
# ---------------------------------------------------------------------------
questa-compile: ibex_questa.flist  manifest_questa.flist
	mkdir -p $(BIN_DIR)
	$(QRUN) $(QUESTA_COMMON_ARGS) -compile

# ---------------------------------------------------------------------------
# Compile-time lint
# ---------------------------------------------------------------------------
questa-lint:  ibex_questa.flist  manifest_questa.flist
	mkdir -p $(BIN_DIR)
	$(QRUN) $(QUESTA_COMMON_ARGS) -compile -lint

# ---------------------------------------------------------------------------
# Simulate compiled design (headless)
# ---------------------------------------------------------------------------
questa-run:  ibex_questa.flist  manifest_questa.flist
	@echo "$(BANNER)"
	@echo "* Running with QuestaSim:"
	@echo "* logfile: $(QUESTA_LOG_DIR)/$(TEST).log"
	@echo "* rtl debug trace: $(QUESTA_LOG_DIR)/trace_core_00000000.log"
	@echo "* *.vcd: $(QUESTA_LOG_DIR)"
	@echo "$(BANNER)"

	mkdir -p $(QUESTA_LOG_DIR)
	rm -f $(QUESTA_LOG_DIR)/*

	@if [ ! -f "$(test-program)-m.hex" ]; then \
		echo "ERROR: Missing file: $(test-program)-m.hex"; \
		exit 1; \
	fi
	@if [ ! -f "$(test-program)-d.hex" ]; then \
		echo "ERROR: Missing file: $(test-program)-d.hex"; \
		exit 1; \
	fi

	$(QRUN) $(QUESTA_COMMON_ARGS) \
	        -batch \
	        -O5 \
	        -nodebug \
	        +acc=none \
	        -logfile $(QUESTA_LOG_DIR)/$(TEST).log \
	        +STIM_INSTR=$(test-program)-m.hex \
	        +STIM_DATA=$(test-program)-d.hex \
	        -do "run -all; quit -f"

	@if [ ! -f "trace_core_00000000.log" ]; then \
		echo "WARNING: Output file missing: trace_core_00000000.log"; \
	else \
		mv trace_core_00000000.log $(QUESTA_LOG_DIR); \
	fi

	@if [ -f "perfcnt.csv" ]; then \
		mv perfcnt.csv $(QUESTA_LOG_DIR)/$(TEST).csv; \
	fi

# ---------------------------------------------------------------------------
# Simulate design with GUI
# ---------------------------------------------------------------------------
questa-gui:  ibex_questa.flist  manifest_questa.flist
	@echo "$(BANNER)"
	@echo "* Running with QuestaSim (GUI):"
	@echo "* logfile: $(QUESTA_LOG_DIR)/$(TEST).log"
	@echo "* rtl debug trace: $(QUESTA_LOG_DIR)/trace_core_00000000.log"
	@echo "* *.vcd: $(QUESTA_LOG_DIR)"
	@echo "$(BANNER)"

	mkdir -p $(QUESTA_LOG_DIR)
	rm -f $(QUESTA_LOG_DIR)/*

	@if [ ! -f "$(test-program)-m.hex" ]; then \
		echo "ERROR: Missing file: $(test-program)-m.hex"; \
		exit 1; \
	fi
	@if [ ! -f "$(test-program)-d.hex" ]; then \
		echo "ERROR: Missing file: $(test-program)-d.hex"; \
		exit 1; \
	fi

	$(QRUN) $(QUESTA_COMMON_ARGS) \
	        -gui \
	        -voptargs=+acc \
	        -logfile $(QUESTA_LOG_DIR)/$(TEST).log \
	        +STIM_INSTR=$(test-program)-m.hex \
	        +STIM_DATA=$(test-program)-d.hex \
	        -do "vcd file questa_tb.vcd; vcd add -r /*; run -all"

# ---------------------------------------------------------------------------
# Headless unit-test run (no hex-file guards)
# ---------------------------------------------------------------------------
questa-run-u-test:  ibex_questa.flist  manifest_questa.flist
	@echo "$(BANNER)"
	@echo "* Running with QuestaSim (unit test):"
	@echo "* logfile: $(QUESTA_LOG_DIR)/$(QUESTA_TOP_MODULE).log"
	@echo "* *.vcd: $(QUESTA_LOG_DIR)"
	@echo "$(shell pwd)"

	mkdir -p $(QUESTA_LOG_DIR)
	rm -f $(QUESTA_LOG_DIR)/questa_tb.vcd

	$(QRUN) $(QUESTA_COMMON_ARGS) \
	        -simulate \
	        -do "vcd file questa_tb.vcd; vcd add -r /*; run -all; quit -f" \
	        $(TEE_CMD) $(QUESTA_LOG_DIR)/$(QUESTA_TOP_MODULE).log

	@if [ -f questa_tb.vcd ]; then \
		mv questa_tb.vcd $(QUESTA_LOG_DIR)/$(QUESTA_TOP_MODULE).vcd; \
	fi
