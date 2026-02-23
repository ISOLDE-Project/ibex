###############################################################################
#
# Copyleft  2024 ISOLDE
#





yosys-manifest.flist: Bender.yml
	$(BENDER) script flist-plus $(common_targs) $(BENDER_EXTRA_TARGET) $(VLT_BENDER)  >$@
	touch $@

pdk-sim.flist: Verilator.yml
	python $(ROOT_DIR)/util/verilator_manifest.py  Verilator.yml \
											    -t  ihp13       \
											    -o $@	
	touch $@

asic-sim.flist:  Bender.yml
	$(BENDER) script verilator $(common_targs) $(BENDER_EXTRA_TARGET) $(VLT_BENDER)  >$@
	touch $@
	
## Generate yosys.flist used to read design in yosys 
yosys.flist:  ibex_synth.tcl
	make  DBG_MODULE=$(DBG_MODULE) \
	      ENABLE_SPM=$(ENABLE_SPM) \
		  BENDER_EXTRA_TARGET="-t yosys" \
		  vivado-clean  $<  \
		  yosys-manifest.flist
	tclsh $(ROOT_DIR)/yosys/scripts/vivado_tcl_to_yosys_f.tcl $<
	@cat  ibex-yosys.flist yosys-manifest.flist >$@	
	touch $@
