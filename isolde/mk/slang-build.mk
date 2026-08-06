###############################################################################
#
# Copyleft 2024 ISOLDE
#
###############################################################################

############
# slang
############

SLANG_TOP_MODULE ?= $(VLT_TOP_MODULE)

SLANG_LOG_DIR  ?= $(mkfile_path)/log/$(VLT_TOP_MODULE)/$(IMEM_LATENCY)
SLANG_LOG      := $(SLANG_LOG_DIR)/slang_lint.log
SLANG_WARNINGS := $(SLANG_LOG_DIR)/slang_warnings.log


.PHONY: slang slang-clean slang-deps slang-lint

# Slang warnings to suppress
#SLANG_WARNINGS_SUPPRESS += unconnected-output-port
SLANG_WARNINGS_SUPPRESS += finish-num
#SLANG_WARNINGS_SUPPRESS += unconnected-input-port

SLANG_WARNING_FLAGS := $(foreach w,$(SLANG_WARNINGS_SUPPRESS),-Wno-$(w))
SLANG_W_EVERYTHING  := --Weverything

# ---------------------------------------------------------------------------
# Clean generated flists
# ---------------------------------------------------------------------------
slang-clean:
	rm -f *.slang

# ---------------------------------------------------------------------------
# Generate slang flists
# ---------------------------------------------------------------------------
%.slang: %.flist
	python $(ROOT_DIR)/util/flist2slang.py $< -o $@ -ops $@_opts


# ---------------------------------------------------------------------------
# Run Slang
# ---------------------------------------------------------------------------
## slang
slang: $(SLANG_TOP_MODULE)_all_deps.f
	$(SLANG) --top $(SLANG_TOP_MODULE) \
		--timescale 1ns/1ps \
		-f ibex_sim.slang_opts  \
		-f manifest.slang_opts   \
		-f $(SLANG_TOP_MODULE)_all_deps.f \
		2>&1 | tee "$(SLANG_LOG_DIR)/$(SLANG_TOP_MODULE)_lint.log" | \
		gawk -v warnings_file="$(SLANG_LOG_DIR)/$(SLANG_TOP_MODULE)_warnings.log" -f "$(SCRIPTS_DIR)/questa.awk"

$(SLANG_TOP_MODULE)_all_deps.f: slang-deps

## slang-lint
slang-lint: ibex_sim.slang manifest.slang
	@mkdir -p "$(SLANG_LOG_DIR)"
	$(SLANG) --top $(SLANG_TOP_MODULE) \
		--timescale 1ns/1ps \
		$(SLANG_W_EVERYTHING) \
		-f ibex_sim.slang \
		-f manifest.slang 2>&1 | \
		tee "$(SLANG_LOG)" | \
		gawk -v warnings_file="$(SLANG_WARNINGS)" -f "$(SCRIPTS_DIR)/questa.awk"


slang-deps: ibex_sim.slang manifest.slang
	$(SLANG) --top $(SLANG_TOP_MODULE) \
		--timescale 1ns/1ps \
		$(SLANG_WARNING_FLAGS) \
		-f ibex_sim.slang \
		-f manifest.slang  \
       --Mmodule $(SLANG_TOP_MODULE)_all_deps.f \
	   --depfile-sort \
	   --depfile-trim



