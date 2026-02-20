###############################################################################
#
# Copyleft  2024 ISOLDE
#





yosys-manifest.flist: Bender.yml
	$(BENDER) script flist-plus $(common_targs) $(BENDER_EXTRA_TARGET) $(VLT_BENDER)  >$@
	touch $@


asic-sim.flist: Bender.yml
	$(BENDER) script verilator $(common_targs) $(BENDER_EXTRA_TARGET) $(VLT_BENDER)  >$@
	touch $@