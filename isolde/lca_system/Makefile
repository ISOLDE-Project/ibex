

mkfile_path    := $(shell git rev-parse --show-toplevel)/isolde/lca_system
REDMULE_ROOT_DIR :=$(shell bender path redmule)
#
CV_SIMULATOR         :=  verilator
CV_SW_TOOLCHAIN      :=  $(shell git rev-parse --show-toplevel)/install/riscv-gcc
CV_SW_PREFIX         :=  riscv32-unknown-elf-
CV_SW_MARCH          :=  rv32im_zicsr
CV_SW_CC             :=  gcc 



include Makefile.verilator


clean-bender:
	rm -f Bender.lock
	rm -fr .bender/
	rm -f manifest.flist


golden:
	make -C $(REDMULE_ROOT_DIR) $@


.PHONY: clean

clean:
	rm -fr vsim
	rm -f manifest.flist