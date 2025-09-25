###############################################################################
#
# Copyleft  2024 ISOLDE
#
###############################################################################

.PHONY: vcs-clean vcs-run

# Clean all build directories and temporary files for VCS
vcs-clean: 
	rm -f ibex_vcs_synth.f isolde_vcs_synth.f vcs_synth.f vcs_compile.sh
	rm -rf simv* csrc ucli.key

##
CORE_FILES := $(filter %.core,$(wildcard $(mkfile_path)/*))
CORE_FILES += $(filter %.core,$(wildcard $(ROOT_DIR)/*))
CORE_FILE_NAMES := $(notdir $(CORE_FILES))

# Generate FuseSoC ibex VCS file list (convert Vivado TCL -> .f)
ibex_vcs_synth.f: $(CORE_FILES)
	@echo $(CORE_FILE_NAMES)
	fusesoc --cores-root=$(ROOT_DIR) run --target=sim --setup --no-export --tool=vcs \
		$(FUSESOC_PARAMS) --build-root=$(FUSESOC_SYNTH_ROOT) \
		$(FUSESOC_PKG_NAME) $(FUSESOC_CONFIG_OPTS)
	@FUSESOC_SYNTH_ROOT=$(FUSESOC_SYNTH_ROOT) \
	python3 $(ROOT_DIR)/util/ch_path.py 
	touch $@

# Generate top-level VCS file list with Bender
vcs_synth.f: ibex_vcs_synth.f $(BENDER_RTL_ROOT)/Bender.yml
	@echo 'INFO:  bender script filelist $(common_targs) $(BENDER_SYNTH_TARGET) $(synth_defs)'
	@$(BENDER) script flist $(common_targs) $(BENDER_SYNTH_TARGET) $(synth_defs) > isolde_vcs_synth.f
	cat ibex_vcs_synth.f isolde_vcs_synth.f > $@
	touch $@

# Optional wrapper script for VCS compile
vcs_compile.sh: vcs_synth.f
	@echo '#!/bin/bash' > $@
	@echo 'vcs -full64 -sverilog -debug_pp -f vcs_synth.f -o simv' >> $@
	chmod +x $@

# Build + run in one shot
vcs-run: vcs_compile.sh
	./vcs_compile.sh
	./simv

