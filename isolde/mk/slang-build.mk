###############################################################################
#
# Copyleft 2024 ISOLDE
#
###############################################################################

############
# slang
############

SLANG_TOP_MODULE ?= $(VLT_TOP_MODULE)

.PHONY: slang slang-clean

# Slang warnings to suppress
#SLANG_WARNINGS_SUPPRESS += unconnected-output-port
SLANG_WARNINGS_SUPPRESS += finish-num
#SLANG_WARNINGS_SUPPRESS += unconnected-input-port

SLANG_WARNING_FLAGS := $(foreach w,$(SLANG_WARNINGS_SUPPRESS),-Wno-$(w))


# ---------------------------------------------------------------------------
# Clean generated flists
# ---------------------------------------------------------------------------
slang-clean:
	rm -f *.slang

# ---------------------------------------------------------------------------
# Generate slang flists
# ---------------------------------------------------------------------------
%.slang: %.flist
	python $(ROOT_DIR)/util/flist2slang.py $< -o $@


# ---------------------------------------------------------------------------
# Run Slang
# ---------------------------------------------------------------------------
slang: ibex_sim.slang manifest.slang
	$(SLANG) --top $(SLANG_TOP_MODULE) \
		--timescale 1ns/1ps \
		$(SLANG_WARNING_FLAGS) \
		-f ibex_sim.slang \
		-f manifest.slang

# 	slang -f ibex_isolde.slang.f --top ibex_top --Mmodule needed_files.f --depfile-trim		
slang-deps: ibex_sim.slang manifest.slang
	$(SLANG) --top $(SLANG_TOP_MODULE) \
		--timescale 1ns/1ps \
		$(SLANG_WARNING_FLAGS) \
		--Mmodule needed_files.flist --depfile-trim \
		-f ibex_sim.slang \
		-f manifest.slang  

