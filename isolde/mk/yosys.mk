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

asic-sim.flist: sv-wrapper Bender.yml
	$(BENDER) script verilator $(common_targs) $(BENDER_EXTRA_TARGET) $(VLT_BENDER)  >$@
	touch $@
	