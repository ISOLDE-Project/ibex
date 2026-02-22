include config.mk

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
VLT_TOP_MODULE_PARAMS := -GIMEM_LATENCY=$(IMEM_LATENCY)

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
endif
ifeq ($(ENABLE_SPM),1)
    tb_target += -t spm
endif

tb_target ?= -t vanilla_lca


common_targs +=  $(tb_target)




#include $(mkfile_path)/../mk/redmule.mk
include $(mkfile_path)/../mk/sw-build.mk
include $(mkfile_path)/../mk/verilator-build.mk
include $(mkfile_path)/../mk/vivado.mk
include $(mkfile_path)/../mk/yosys.mk



	


		