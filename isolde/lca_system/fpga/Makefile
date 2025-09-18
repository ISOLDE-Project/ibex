ROOT_DIR            :=  $(shell git rev-parse --show-toplevel)
FPGA_PATH           := $(ROOT_DIR)/isolde/lca_system/fpga
SYS_PATH            := $(ROOT_DIR)/isolde/lca_system
SYS_MAKEFILE        := $(ROOT_DIR)/isolde/lca_system/Makefile

SYNTH_TARGET        = "-t xilinx"

all: vivado-prj

vivado_synth.tcl: Makefile.vivado
	make -f  Makefile.vivado \
			 DBG_MODULE=1 ENABLE_SPM=1 \
	         FUSESOC_SYNTH_ROOT=$(FPGA_PATH) \
			 BENDER_RTL_ROOT=$(SYS_PATH) \
			 BENDER_SYNTH_TARGET=$(SYNTH_TARGET) \
	         $@


.PHONY: vivado-prj
vivado-prj: vivado_synth.tcl	
	vivado -mode batch -source ./create_project.tcl  ./run_linter.tcl

.PHONY: clean
clean:
	- make -f Makefile.vivado vivado-clean || true
	rm -fr vivado
	rm -f  Makefile.vivado *.jou *.log

Makefile.vivado: $(SYS_MAKEFILE)
	cp $< $@

.PHONY: cfg-zcu104
cfg-zcu104:
	cp board/xilinx_zcu104.cfg board/xilinx.cfg
