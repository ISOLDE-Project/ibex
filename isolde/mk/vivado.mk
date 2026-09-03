###############################################################################
#
# Copyleft 2024 ISOLDE
#
# Vivado RTL source flow:
#
#   FuseSoC synth target  --\
#                           +--> Verilator-style flists
#   Bender synth targets  --/             |
#                                         v
#                                      Slang
#                               --top xilinx_aida
#                               --depfile-sort
#                               --depfile-trim
#                                         |
#                                         v
#                            xilinx_aida_all_deps.f
#                                         |
#                                         v
#                              vivado_synth.tcl
#
###############################################################################

VIVADO_TOP_MODULE ?= xilinx_aida

FUSESOC_SYNTH_TARGET      := synth
FUSESOC_SYNTH_TOOL        := verilator
FUSESOC_SYNTH_OUTPUT_DIR  := $(FUSESOC_SYNTH_ROOT)/$(FUSESOC_SYNTH_TARGET)-$(FUSESOC_SYNTH_TOOL)
FUSESOC_SYNTH_OUTPUT_FILE := $(FUSESOC_SYNTH_OUTPUT_DIR)/$(FUSESOC_PROJECT)_$(FUSESOC_CORE)_$(FUSESOC_SYSTEM)_0.vc

###############################################################################
# Register the Vivado/FPGA dependency universe with slang-build.mk.
#
# The FuseSoC target parameters (-G...) belong to ibex_top, whereas dependency
# extraction is rooted at xilinx_aida.  Use the .deps.slang variants so those
# top-level parameter overrides are not incorrectly applied to xilinx_aida.
###############################################################################

SLANG_INPUTS_$(VIVADO_TOP_MODULE) := \
	ibex_synth.slang \
	manifest_synth.slang
	
SLANG_DEPS_FLAGS_$(VIVADO_TOP_MODULE) := \
	--ignore-unknown-modules
.PHONY: vivado-clean vivado-deps

###############################################################################
# Clean
###############################################################################

vivado-clean:
	rm -f ibex_synth.flist manifest_synth.flist
	rm -f ibex_synth.slang ibex_synth.slang_opts ibex_synth.slang_veri_opts
	rm -f manifest_synth.slang manifest_synth.slang_opts manifest_synth.slang_veri_opts
	rm -f ibex_synth.deps.slang manifest_synth.deps.slang
	rm -f $(VIVADO_TOP_MODULE)_all_deps.f
	rm -f ibex_synth.tcl isolde_synth.tcl vivado_synth.tcl
	rm -fr synth-vivado
	rm -fr $(FUSESOC_SYNTH_OUTPUT_DIR)

###############################################################################
# FuseSoC: broad Ibex synthesis source universe.
#
# Verilator is used only as a convenient .vc serializer.  tool_vivado is
# explicitly set so tool-conditioned FuseSoC configuration still follows the
# FPGA/Xilinx path (e.g. FPGA_XILINX).
###############################################################################

VIVADO_CORE_FILES := $(filter %.core,$(wildcard $(mkfile_path)/*))
VIVADO_CORE_FILES += $(filter %.core,$(wildcard $(ROOT_DIR)/*))
VIVADO_CORE_FILE_NAMES := $(notdir $(VIVADO_CORE_FILES))

ibex_synth.flist: $(VIVADO_CORE_FILES)
	@echo $(VIVADO_CORE_FILE_NAMES)
	fusesoc --cores-root=$(ROOT_DIR) run \
		--target=$(FUSESOC_SYNTH_TARGET) \
		--tool=$(FUSESOC_SYNTH_TOOL) \
		--flag tool_vivado \
		--setup \
		--no-export \
		$(FUSESOC_PARAMS) \
		--build-root=$(FUSESOC_SYNTH_ROOT) \
		$(FUSESOC_PKG_NAME) \
		$(FUSESOC_CONFIG_OPTS)
	python $(ROOT_DIR)/util/transform_paths.py \
		$(FUSESOC_SYNTH_OUTPUT_DIR) \
		$(FUSESOC_SYNTH_OUTPUT_FILE) \
		$@

###############################################################################
# Bender: broad ISOLDE FPGA synthesis source universe.
#
# "script verilator" selects only the output syntax here.  Suppress Bender's
# normal Verilator default targets and explicitly restore synthesis/Vivado
# semantics; BENDER_SYNTH_TARGET supplies board/design targets such as
# "-t xilinx" and defines such as REDMULE_CLUSTER.
###############################################################################

manifest_synth.flist: $(BENDER_RTL_ROOT)/Bender.yml
	$(BENDER) script verilator \
		--no-default-target \
		-t synthesis \
		-t vivado \
		$(common_targs) \
		$(BENDER_SYNTH_TARGET) \
		$(synth_defs) \
		>$@
	touch $@
###############################################################################
# Slang-trimmed dependency set.
#
# The actual recipe is the generic %_all_deps.f rule in slang-build.mk.
###############################################################################

vivado-deps: $(VIVADO_TOP_MODULE)_all_deps.f

###############################################################################
# Final Vivado source manifest.
#
# Keep the existing create_project.tcl interface:
#   - ibex_include_dirs
#   - ibex_verilog_defines
#
# The helper collects include directories / defines from the broad Slang
# manifests, while the actual source list comes only from Slang's trimmed,
# topologically sorted dependency file.
###############################################################################

vivado_synth.tcl: \
		$(VIVADO_TOP_MODULE)_all_deps.f \
		ibex_synth.slang \
		manifest_synth.slang
	python $(ROOT_DIR)/util/slang_deps_to_vivado.py \
		--deps $(VIVADO_TOP_MODULE)_all_deps.f \
		--options ibex_synth.slang manifest_synth.slang \
		--output $@