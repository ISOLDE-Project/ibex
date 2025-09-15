ROOT_DIR            :=  $(shell git rev-parse --show-toplevel)
fpga_path           := $(ROOT_DIR)/isolde/lca_system/fpga

all:
	make -C $(ROOT_DIR)/isolde/lca_system \
	         FUSESOC_SYNTH_ROOT=$(fpga_path) \
			 BENDER_RTL_ROOT=$(ROOT_DIR)/isolde/lca_system \
	                vivado-clean vivado_synth.tcl

.PHONY: clean
clean:
	rm -fr synth-vivado
	rm -f  ibex_synth.tcl