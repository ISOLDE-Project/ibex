ROOT_DIR            :=  $(shell git rev-parse --show-toplevel)
FPGA_DIR            := $(ROOT_DIR)/isolde/system/fpga
SYS_DIR             := $(ROOT_DIR)/isolde/system
SYS_MAKEFILE        := $(ROOT_DIR)/isolde/system/Makefile

export FPGA_DIR

###############################################################################
# Build configuration
#
#   BOARD       selects board/xilinx_$(BOARD).cfg  -> board/xilinx.cfg
#   CLUSTER=1   builds cluster_top  (adds -D REDMULE_CLUSTER, forces SPM on),
#   CLUSTER=0   builds aida_top     (non-cluster SoC, see Makefile.nospm)
#
# CLUSTER must match the define used by vendor/isolde-soc/fpga/rtl/xilinx_aida.sv
# and by vendor/isolde-soc/fpga/tb/aida_tb.sv, so that simulation and FPGA
# elaborate the same SoC.
###############################################################################
BOARD               ?= zcu104
CLUSTER             ?= 1
ENABLE_SPM          ?= 1

BOARD_CFG           := $(FPGA_DIR)/board/xilinx.cfg

SYNTH_TARGET        := -t xilinx
ifeq ($(CLUSTER),1)
SYNTH_TARGET        += -D REDMULE_CLUSTER
# cluster_top is guarded by `ifdef TARGET_SPM
ENABLE_SPM          := 1
else
$(warning CLUSTER=0: rtl/isolde_exec_block.sv uses xif_issue_if.hwe_id / \
interrupt_enable_mask / cluster_status, which vendor/core-v-xif declares only \
under `ifdef REDMULE_CLUSTER. Elaboration will fail until that file is guarded.)
endif

VIVADO_TOP_MODULE     := $(or $(shell sed -n 's/^set _top_module_[[:space:]]*"\?\([A-Za-z_0-9]*\)"\?.*/\1/p' $(BOARD_CFG) 2>/dev/null),xilinx_aida)
MAKEFILE_VIVADO_BASE  := $(MAKE) -f Makefile.vivado \
									VIVADO_TOP_MODULE=$(VIVADO_TOP_MODULE) \
									DBG_MODULE=1 ENABLE_SPM=$(ENABLE_SPM) \
									FUSESOC_SYNTH_ROOT=$(FPGA_DIR) \
									BENDER_RTL_ROOT=$(SYS_DIR) \
									"BENDER_SYNTH_TARGET=$(SYNTH_TARGET)" 


.DEFAULT_GOAL:=help

all: vivado-prj

###############################################################################
# Board selection
#   board/xilinx.cfg is gitignored: it is the single file every tcl script
#   sources, and it is a copy of the selected board/xilinx_<board>.cfg.
###############################################################################
$(BOARD_CFG): $(FPGA_DIR)/board/xilinx_$(BOARD).cfg
	cp $< $@

.PHONY: cfg
cfg:                        ## Selects the board, e.g. `make cfg BOARD=zcu104`
	cp $(FPGA_DIR)/board/xilinx_$(BOARD).cfg $(BOARD_CFG)
	@echo "INFO: board is now $(BOARD)"

.PHONY: cfg-zcu104
cfg-zcu104:                 ## Deprecated: use `make cfg BOARD=zcu104`
	$(MAKE) cfg BOARD=zcu104

.PHONY: boards
boards:                     ## Lists the available board profiles
	@ls $(FPGA_DIR)/board/xilinx_*.cfg | sed 's|.*/xilinx_||;s|\.cfg$$||'

###############################################################################
# Source list generation (fusesoc for ibex, bender for the ISOLDE SoC)
###############################################################################
vivado_synth.tcl: Makefile.vivado $(FPGA_DIR)/ips/xilinx_sys_rst/xilinx_sys_rst.xpr $(FPGA_DIR)/ips/xilinx_clk_mngr/xilinx_clk_mngr.xpr
	$(MAKEFILE_VIVADO_BASE) \
	         $@


.PHONY: vivado-prj
vivado-prj: $(BOARD_CFG) vivado_synth.tcl 	## Creates the vivado project.
	vivado -mode batch -source ./tcl/create_project.tcl


.PHONY: lint
lint: $(BOARD_CFG) vivado_synth.tcl	      ## Creates the vivado project and runs linter.
	vivado -mode batch -source ./tcl/create_project.tcl  ./tcl/run_linter.tcl

.PHONY: synth
synth: $(BOARD_CFG) vivado_synth.tcl	      ## Creates the vivado project and runs synthesis.
	vivado -mode batch -source ./tcl/create_project.tcl  ./tcl/synth.tcl

.PHONY: impl
impl: $(BOARD_CFG) vivado_synth.tcl	      ## Creates the vivado project and generates the bitstream.
	vivado -mode batch -source ./tcl/create_project.tcl  ./tcl/run.tcl

.PHONY: rpt
rpt: $(BOARD_CFG) vivado_synth.tcl	      ## Opens the vivado project and generates a brief timing summary.
	vivado -mode batch -source  ./tcl/report.tcl

.PHONY: clean vivado-clean
clean: vivado-clean                      ## Removes all build products
	$(MAKE) -C $(FPGA_DIR)/ips/xilinx_clk_mngr  $@
	$(MAKE) -C $(FPGA_DIR)/ips/xilinx_sys_rst   $@
	rm -f  Makefile.vivado

vivado-clean:   ## Removes the generated files together with the vivado project
	$(MAKEFILE_VIVADO_BASE) $@
	rm -f  vivado_synth.tcl
	rm -fr vivado 
	rm -f  *.jou *.log
	
	
	


Makefile.vivado: $(SYS_MAKEFILE)
	cp $< $@


vivado-stats:  Makefile.vivado ## Statistics on trimmed files
	$(MAKEFILE_VIVADO_BASE) $@

vivado-deps:  Makefile.vivado ## build up the dependency list for the top module
	$(MAKEFILE_VIVADO_BASE) $@
	@printf "\033[33mINFO: See $(VIVADO_TOP_MODULE)_all_deps.f for the full dependency list.\033[0m\n"
	

###############################################################################
# Out-of-context IPs. They read part/board_part from board/xilinx.cfg through
# tcl/common.tcl, so the board must be selected before they are built.
###############################################################################
$(FPGA_DIR)/ips/xilinx_sys_rst/xilinx_sys_rst.xpr: $(BOARD_CFG)
	$(MAKE) -C $(FPGA_DIR)/ips/xilinx_sys_rst all

$(FPGA_DIR)/ips/xilinx_clk_mngr/xilinx_clk_mngr.xpr: $(BOARD_CFG)
	$(MAKE) -C $(FPGA_DIR)/ips/xilinx_clk_mngr all

help: Makefile.vivado  ## Shows this help message
	@printf "\033[33mINFO: FPGA_DIR: $(FPGA_DIR)\033[0m\n"
	@printf "\033[33mINFO: Top module: $(VIVADO_TOP_MODULE)\033[0m\n"
	@printf "\033[33mINFO: BOARD=$(BOARD)  CLUSTER=$(CLUSTER)  ENABLE_SPM=$(ENABLE_SPM)\033[0m\n"
	@grep -E -h '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'
