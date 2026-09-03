###############################################################################
#
# Copyleft 2024 ISOLDE
#
# slang lint / dependency-extraction flow
#
# Two-phase design:
#   Phase 1 (dependency extraction):
#       Generate a trimmed, topologically sorted *_all_deps.f for any
#       registered top module.
#
#   Phase 2 (slang):
#       Curated re-run on the trimmed simulation dependency set.
#       All warnings should be fixed.
#
###############################################################################

# Fail pipelines if any stage (e.g. slang) fails, not just the last (gawk).
SHELL       := /bin/bash
.SHELLFLAGS := -o pipefail -c

SLANG_TOP_MODULE ?= $(VLT_TOP_MODULE)

# NOTE: verify $(mkfile_path) resolves to a directory. If it is a makefile
# path, use $(dir $(mkfile_path)) instead.
SLANG_LOG_DIR ?= $(mkfile_path)/log/slang/$(VLT_TOP_MODULE)/$(IMEM_LATENCY)

# --- Phase 1 (broad lint) logs ---------------------------------------------
SLANG_LINT_LOG  := $(SLANG_LOG_DIR)/$(SLANG_TOP_MODULE)_lint_full.log
SLANG_LINT_WARN := $(SLANG_LOG_DIR)/$(SLANG_TOP_MODULE)_lint_full_warnings.log

# --- Phase 2 (strict curated lint) logs ------------------------------------
SLANG_LOG       := $(SLANG_LOG_DIR)/$(SLANG_TOP_MODULE)_lint.log
SLANG_WARNINGS  := $(SLANG_LOG_DIR)/$(SLANG_TOP_MODULE)_warnings.log

.PHONY: slang slang-clean slang-deps slang-lint

# Enable all warnings.
SLANG_W_EVERYTHING := \
	-Wempty-connection \
	-Wconversion \
	-Wextra \
	-Wparentheses \
	-Wpedantic \
	-Wshadow \
	-Wunconnected-port \
	-Wunused

# Slang warnings to suppress.
SLANG_WARNINGS_SUPPRESS +=
#SLANG_WARNINGS_SUPPRESS += unconnected-output-port
SLANG_WARNINGS_SUPPRESS += finish-num
#SLANG_WARNINGS_SUPPRESS += unconnected-input-port

SLANG_WARNING_FLAGS := $(foreach w,$(SLANG_WARNINGS_SUPPRESS),-Wno-$(w))
SLANG_WARNING_FLAGS += -Wunused-wildcard-import -Wunused-parameter

###############################################################################
# Common Slang command line
#
# SLANG_COMMON intentionally does not contain --top.  Dependency extraction
# derives the top from the stem of <top>_all_deps.f, which makes the mechanism
# reusable by Verilator, Vivado and other flows.
#
# SLANG_BASE keeps the historical simulation/lint behaviour.
###############################################################################

SLANG_VERSION_STR := $(strip $(shell $(SLANG) --version 2>/dev/null))

ifeq ($(SLANG_VERSION_STR),slang version 11.0.447+430286070)
  SLANG_COMMON := $(SLANG) --timescale 1ns/1ps --waiver-file .slang/slang-waivers.toml
else
  SLANG_COMMON := $(SLANG) --timescale 1ns/1ps
endif

SLANG_BASE := $(SLANG_COMMON) --top $(SLANG_TOP_MODULE)

$(info ⚠️  Using slang: $(SLANG_VERSION_STR))
$(info ⚠️  SLANG_BASE=$(SLANG_BASE))

###############################################################################
# Clean
###############################################################################

slang-clean:
	rm -f *.slang *.slang* $(SLANG_TOP_MODULE)_all_deps.f

###############################################################################
# Verilator-style flist -> Slang command files.
###############################################################################

%.slang: %.flist
	python $(ROOT_DIR)/util/flist2slang.py $< -o $@ \
		-ops $@_opts \
		-veri $@_veri_opts

###############################################################################
# Dependency-elaboration variant.
#
# A .deps.slang file contains the same sources / include directories / defines
# as its corresponding .slang file, but drops top-level -G overrides.
#
# This is required when a manifest was generated for one top (e.g. ibex_top)
# but dependency extraction elaborates an outer wrapper (e.g. xilinx_aida).
###############################################################################

%.deps.slang: %.slang
	sed '/^[[:space:]]*-G[[:space:]]/d' $< >$@

###############################################################################
# Register the simulation dependency universe.
#
# Other flows register their own inputs by defining:
#
#   SLANG_INPUTS_<top> := file1.slang file2.slang ...
#
# For example vivado.mk registers SLANG_INPUTS_xilinx_aida.
###############################################################################

# SLANG_INPUTS_$(SLANG_TOP_MODULE) := ibex_sim.slang manifest.slang

###############################################################################
# Generic dependency extraction.
#
# Example:
#
#   make aida_tb_all_deps.f
#     -> stem $* = aida_tb
#     -> prerequisites = $(SLANG_INPUTS_aida_tb)
#     -> Slang --top aida_tb
#
#   make xilinx_aida_all_deps.f
#     -> stem $* = xilinx_aida
#     -> prerequisites = $(SLANG_INPUTS_xilinx_aida)
#     -> Slang --top xilinx_aida
#
# Secondary expansion is required because the stem is only known when Make
# matches the implicit pattern rule.
###############################################################################

.SECONDEXPANSION:

%_all_deps.f: $$(SLANG_INPUTS_$$*)
	@echo "⚠️  Phase 1: slang dependency extraction: $@"
	@echo "🔔  slang warnings can be safely ignored"
	@if [ -z "$(strip $(SLANG_INPUTS_$*))" ]; then \
		echo "ERROR: no Slang input set registered for top '$*'"; \
		echo "       define SLANG_INPUTS_$*"; \
		exit 1; \
	fi
	$(SLANG_COMMON) \
		--top $* \
		$(foreach f,$^,-f $(f)) \
		--Mmodule $@ \
		--depfile-sort \
		--depfile-trim



###############################################################################
# Phase 2: strict curated simulation lint.
###############################################################################

%_slang: %_all_deps.f
	@echo "⚠️  Phase 2: slang lint: $<"
	@echo "🔥  slang warnings should be addressed"
	@mkdir -p "$(SLANG_LOG_DIR)"
	@: > "$(SLANG_WARNINGS)"
	$(SLANG_COMMON) \
		--top $* \
		$(foreach f,$(SLANG_OPTS_$*),-f $(f)) \
		-f $< \
		2>&1 | tee "$(SLANG_LOG)" | \
		gawk -v warnings_file="$(SLANG_WARNINGS)" \
		      -f "$(SCRIPTS_DIR)/questa.awk"
	@if [ -s "$(SLANG_WARNINGS)" ]; then \
		echo "ERROR: phase 2 (slang) must be clean, but diagnostics remain:"; \
		echo "$(SLANG_WARNINGS)"; \
	else \
		echo "slang phase 2 clean: 0 diagnostics."; \
	fi

###############################################################################
# Broad simulation lint.
###############################################################################

slang-lint: ibex_sim.slang manifest.slang $(SLANG_TOP_MODULE)_all_deps.f
	@mkdir -p "$(SLANG_LOG_DIR)"
	$(SLANG_BASE) \
		$(SLANG_W_EVERYTHING) \
		-f ibex_sim.slang_opts \
		-f manifest.slang_opts \
		-f $(SLANG_TOP_MODULE)_all_deps.f \
		2>&1 | tee "$(SLANG_LINT_LOG)" | \
		gawk -v warnings_file="$(SLANG_LINT_WARN)" -f "$(SCRIPTS_DIR)/questa.awk"