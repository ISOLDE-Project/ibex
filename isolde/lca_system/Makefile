

mkfile_path    := $(shell git rev-parse --show-toplevel)/isolde/lca_system
## ibex config
ROOT_DIR            :=  $(shell git rev-parse --show-toplevel)
IBEX_CONFIG         ?=  isolde
FUSESOC_CONFIG_OPTS := $(shell cd $(ROOT_DIR) && $(ROOT_DIR)/util/ibex_config.py $(IBEX_CONFIG) fusesoc_opts)
TEST                ?= vlinstr_test
test-program        ?= $(ROOT_DIR)/isolde/sw/simple_system/$(TEST)/$(TEST).elf
#BUILD_DIR           := build/$(IBEX_CONFIG)
#SYNTH_DIR           := synth/$(IBEX_CONFIG)
TMP_DIR             := tmp/$(IBEX_CONFIG)
## redmule config
REDMULE_ROOT_DIR :=$(shell bender path redmule)
#
CV_SIMULATOR         :=  verilator
CV_SW_TOOLCHAIN      :=  $(shell git rev-parse --show-toplevel)/install/riscv-gcc
CV_SW_PREFIX         :=  riscv32-unknown-elf-
CV_SW_MARCH          :=  rv32im_zicsr
CV_SW_CC             :=  gcc 



include Makefile.verilator

fusesoc_ignore: $(ROOT_DIR)/isolde/lca_system/.bender/FUSESOC_IGNORE $(ROOT_DIR)/vendor/redmule/FUSESOC_IGNORE


$(ROOT_DIR)/isolde/lca_system/.bender/FUSESOC_IGNORE:
	touch $@

$(ROOT_DIR)/vendor/redmule/FUSESOC_IGNORE:
	touch $@


ibex_sim.flist: fusesoc_ignore
	fusesoc   --cores-root=$(ROOT_DIR) run --target=sim --setup --no-export --build-root=$(TMP_DIR) isolde:ibex:lca_system $(FUSESOC_CONFIG_OPTS) | tee fusesoc.log
	python $(ROOT_DIR)/util/transform_paths.py  \
										       $(ROOT_DIR)/isolde/lca_system/tmp/isolde/sim-verilator  \
	                                           $(ROOT_DIR)/isolde/lca_system/tmp/isolde/sim-verilator/isolde_ibex_lca_system_0.vc \
											   $@


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