ROOT_DIR            :=  $(shell git rev-parse --show-toplevel)
mkfile_path         := $(ROOT_DIR)/isolde/system
SCRIPTS_DIR         := $(ROOT_DIR)/isolde/scripts
IBEX_CONFIG         ?=  isolde
FUSESOC_CONFIG_OPTS ?= 
FUSESOC_PARAMS      ?=
TEST                ?= dhrystone
TEST_SRC_DIR	    = $(ROOT_DIR)/isolde/sw/$(TEST)
TEST_BIN_DIR	    = $(mkfile_path)/sw/bin
test-program        ?= $(TEST_BIN_DIR)/$(TEST)
BUILD_DIR           := build/$(IBEX_CONFIG)
SYNTH_DIR           := synth/$(IBEX_CONFIG)
TMP_DIR             := tmp/$(IBEX_CONFIG)
FUSESOC_BUILD_ROOT  := $(mkfile_path)/$(TMP_DIR)
FUSESOC_SYNTH_ROOT  ?= $(mkfile_path)/$(SYNTH_DIR)
BENDER_RTL_ROOT     ?= $(mkfile_path)
BENDER_SYNTH_TARGET ?= 
BENDER_EXTRA_TARGET ?= -t aida_mmio
FUSESOC_PROJECT     := isolde
FUSESOC_CORE        := ibex
FUSESOC_SYSTEM      := lca_dm_system
FUSESOC_PKG_NAME    := $(FUSESOC_PROJECT):$(FUSESOC_CORE):$(FUSESOC_SYSTEM)
ONNX_MLIR           := $(ROOT_DIR)/install/onnx-mlir/bin/onnx-mlir
##

ifeq ($(COMPILER), gcc)
CV_SW_TOOLCHAIN      :=  $(shell git rev-parse --show-toplevel)/install/riscv-gcc
CV_SW_PREFIX         :=  riscv32-unknown-elf-
CV_SW_MARCH          :=  rv32im_zicsr
	CV_SW_CC_SUFFIX      :=  gcc 

else

	CV_SW_TOOLCHAIN      :=  $(shell git rev-parse --show-toplevel)/install/riscv-llvm
	CV_SW_PREFIX         :=  
	CV_SW_MARCH          :=  rv32im_zicsr
	CV_SW_CC_SUFFIX      :=  clang
endif





###
VLT_TOP_MODULE        ?= tb_lca_system
IMEM_LATENCY          ?= 0
WAVES                 ?= 0
VLT_TOP_MODULE_PARAMS := -GIMEM_LATENCY=$(IMEM_LATENCY)

ifneq ($(filter $(WAVES),0 1),$(WAVES))
$(error WAVES must be 0 or 1)
endif

###
# Static configurations (can be overridden by command-line)
###
DBG_MODULE   ?= 0
ENABLE_SPM   ?= 0

REDMULE_COMPLEX ?= 1
export REDMULE_COMPLEX

verilator_target := vanilla
# Select testbench target 
ifeq ($(DBG_MODULE),1)
    tb_target += -t tb_dm -t rv_debug
	verilator_target := tb_dm
endif
ifeq ($(ENABLE_SPM),1)
    tb_target += -t spm
endif

tb_target ?= -t vanilla_lca


common_targs +=  $(tb_target)


include $(mkfile_path)/../mk/yosys.mk


include $(mkfile_path)/../mk/redmule.mk
include $(mkfile_path)/../mk/sw-build.mk
include $(mkfile_path)/../mk/verilator-build.mk
include $(mkfile_path)/../mk/questa-build.mk
include $(mkfile_path)/../mk/slang-build.mk
include $(mkfile_path)/../mk/vivado.mk
include $(mkfile_path)/../mk/bender-wrapper.mk
include $(ROOT_DIR)/common.mk


generate:
	make -C $(ROOT_DIR)/vendor/isolde-soc -f Makefile.jinja N_TILES=2 clean generate
	
## apply slang patches	
patch:
	make -C $(mkfile_path)/patches/fpnew
		