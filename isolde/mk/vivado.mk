###############################################################################
#
# Copyleft  2024 ISOLDE
#
###############################################################################

.PHONY: vivado-clean 

# Clean all build directories and temporary files for vivado
vivado-clean: 
	rm -f ibex_synth.tcl isolde_synth.tcl vivado_synth.tcl
	rm -fr synth-vivado 
##
CORE_FILES := $(filter %.core,$(wildcard $(mkfile_path)/*))
CORE_FILES += $(filter %.core,$(wildcard $(ROOT_DIR)/*))
CORE_FILE_NAMES := $(notdir $(CORE_FILES))

ibex_synth.tcl:  $(CORE_FILES)
	@echo $(CORE_FILE_NAMES)
	fusesoc --cores-root=$(ROOT_DIR) run --target=synth --setup --no-export $(FUSESOC_PARAMS)  --build-root=$(FUSESOC_SYNTH_ROOT) $(FUSESOC_PKG_NAME) $(FUSESOC_CONFIG_OPTS) 
	python $(ROOT_DIR)/util/convert_vivado_tcl.py  \
	 									       $(FUSESOC_SYNTH_ROOT)/synth-vivado/isolde_ibex_lca_dm_system_0.tcl  \
	 										   $@ \
											   $(FUSESOC_SYNTH_ROOT)/synth-vivado
	touch $@
##

vivado_synth.tcl: ibex_synth.tcl  $(BENDER_RTL_ROOT)/Bender.yml 
	@echo 'INFO:  bender script vivado $(common_targs) $(BENDER_SYNTH_TARGET) $(synth_defs) '
	@$(BENDER) script vivado $(common_targs) $(BENDER_SYNTH_TARGET) $(synth_defs) >isolde_synth.tcl
	cat  ibex_synth.tcl isolde_synth.tcl >$@
	touch $@



	
