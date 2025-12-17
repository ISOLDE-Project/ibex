ROOT_DIR            :=  $(shell git rev-parse --show-toplevel)
FPGA_DIR            := $(ROOT_DIR)/isolde/system/fpga
SYS_DIR            := $(ROOT_DIR)/isolde/system
SYS_MAKEFILE        := $(ROOT_DIR)/isolde/system/Makefile

export FPGA_DIR

SYNTH_TARGET        += "-t xilinx"

.DEFAULT_GOAL:=help

all: vivado-prj

vivado_synth.tcl: Makefile.vivado $(FPGA_DIR)/ips/xilinx_sys_rst/xilinx_sys_rst.xpr $(FPGA_DIR)/ips/xilinx_clk_mngr/xilinx_clk_mngr.xpr
	make -f  Makefile.vivado \
			 DBG_MODULE=1 ENABLE_SPM=1 \
	         FUSESOC_SYNTH_ROOT=$(FPGA_DIR) \
			 BENDER_RTL_ROOT=$(SYS_DIR) \
			 BENDER_SYNTH_TARGET=$(SYNTH_TARGET) \
	         $@


.PHONY: vivado-prj
vivado-prj: vivado_synth.tcl 	## Creates the vivado project.
	vivado -mode batch -source ./tcl/create_project.tcl  


.PHONY: lint
lint: vivado_synth.tcl	      ## Creates the vivado project and runs linter.
	vivado -mode batch -source ./tcl/create_project.tcl  ./tcl/run_linter.tcl

.PHONY: synth
synth: vivado_synth.tcl	      ## Creates the vivado project and runs synthesis.
	vivado -mode batch -source ./tcl/create_project.tcl  ./tcl/synth.tcl

.PHONY: impl
impl: vivado_synth.tcl	      ## Creates the vivado project and generates the bitstream.
	vivado -mode batch -source ./tcl/create_project.tcl  ./tcl/run.tcl	

.PHONY: rpt
rpt: vivado_synth.tcl	      ## Opens the vivado project and generates a brief timing summary.
	vivado -mode batch -source  ./tcl/report.tcl	

.PHONY: clean clean-vivado
clean:                      ## Removes all build products
	- make -f Makefile.vivado vivado-clean || true
	rm -fr vivado synth-vivado
	rm -f  Makefile.vivado *.jou *.log
	rm -f ibex_synth.tcl isolde_synth.tcl vivado_synth.tcl
	make -C $(FPGA_DIR)/ips/xilinx_clk_mngr  $@
	make -C $(FPGA_DIR)/ips/xilinx_sys_rst   $@

clean-vivado:              ## Removes the generated files together with the vivado project
	rm -fr vivado synth-vivado
	rm -f ibex_synth.tcl isolde_synth.tcl vivado_synth.tcl

Makefile.vivado: $(SYS_MAKEFILE)
	cp $< $@

.PHONY: cfg-zcu104
cfg-zcu104:             ## Makes current board ZCU104
	cp board/xilinx_zcu104.cfg board/xilinx.cfg

$(FPGA_DIR)/ips/xilinx_sys_rst/xilinx_sys_rst.xpr:
	make -C $(FPGA_DIR)/ips/xilinx_sys_rst all

$(FPGA_DIR)/ips/xilinx_clk_mngr/xilinx_clk_mngr.xpr:
	make -C $(FPGA_DIR)/ips/xilinx_clk_mngr all

help: ## Shows this help message
	@echo $(FPGA_DIR)
	@grep -E -h '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'