ROOT_DIR            :=  $(shell git rev-parse --show-toplevel)
mkfile_path         := $(shell git rev-parse --show-toplevel)/isolde/simple_system
IBEX_CONFIG         ?=  isolde
FUSESOC_CONFIG_OPTS := $(shell cd $(ROOT_DIR) && $(ROOT_DIR)/util/ibex_config.py $(IBEX_CONFIG) fusesoc_opts)
FUSESOC_PARAMS      ?=
TEST                ?= vlinstr_test
test-program        ?= $(ROOT_DIR)/isolde/sw/simple_system/$(TEST)/$(TEST).elf
BUILD_DIR           := build/$(IBEX_CONFIG)
SYNTH_DIR           := synth/$(IBEX_CONFIG)
TMP_DIR             := tmp/$(IBEX_CONFIG)
FUSESOC_BUILD_ROOT  :=$(mkfile_path)/$(TMP_DIR)
FUSESOC_PROJECT     := isolde
FUSESOC_CORE        := ibex
FUSESOC_SYSTEM      := ibex_simple_system
FUSESOC_PKG_NAME    := $(FUSESOC_PROJECT):$(FUSESOC_CORE):$(FUSESOC_SYSTEM)

num_cores := $(shell nproc)
num_cores_half := $(shell echo "$$(($(num_cores) / 2))")


include Makefile.verilator

CORE_FILES := $(filter %.core,$(wildcard $(mkfile_path)/*))
CORE_FILES += $(filter %.core,$(wildcard $(ROOT_DIR)/*))

fusesoc_ignore: $(ROOT_DIR)/isolde/lca_system/.bender/FUSESOC_IGNORE $(ROOT_DIR)/vendor/redmule/FUSESOC_IGNORE

$(ROOT_DIR)/isolde/lca_system/.bender/FUSESOC_IGNORE:
	@if [ ! -f $@ ]; then touch $@; fi

$(ROOT_DIR)/vendor/redmule/FUSESOC_IGNORE:
	@if [ ! -f $@ ]; then touch $@; fi



ibex_sim.flist:  $(CORE_FILES)
	@echo $(CORE_FILES)
	fusesoc --cores-root=$(ROOT_DIR) run --target=sim --setup --no-export $(FUSESOC_PARAMS)  --build-root=$(FUSESOC_BUILD_ROOT) $(FUSESOC_PKG_NAME) $(FUSESOC_CONFIG_OPTS) 
	python $(ROOT_DIR)/util/transform_paths.py  \
										       $(FUSESOC_BUILD_ROOT)/sim-verilator  \
	                                           $(FUSESOC_BUILD_ROOT)/sim-verilator/$(FUSESOC_PROJECT)_$(FUSESOC_CORE)_$(FUSESOC_SYSTEM)_0.vc \
											   $@
	touch $@

.PHONY: clean-flist
clean-flist:
	rm -f ibex_sim.flist

synth-setup:
	mkdir -p $(SYNTH_DIR)
	fusesoc --cores-root=$(ROOT_DIR) run --target=synth --setup  --no-export --build-root=$(SYNTH_DIR) isolde:ibex:ibex_simple_system $(FUSESOC_CONFIG_OPTS)

.PHONY: synth
synth: synth-setup
	cd ./synth/isolde/synth-vivado && \
	echo "launch_runs synth_1 " >launch_runs.tcl && \
	echo "wait_on_runs synth_1" >>launch_runs.tcl && \
	vivado -mode batch -source ./isolde_ibex_ibex_simple_system_0.tcl ./launch_runs.tcl | tee vivado.log

	

.PHONY: test-app $(test-program) clean
# Rule for test-program
$(test-program):
	make -C $(dir $@)

test-app: $(test-program)

clean-test:
	make -C $(dir $(test-program)) clean



clean: clean-flist
#	rm -f $(test-program)
	make -C $(dir $(test-program)) clean
	rm -fr $(BUILD_DIR) logs
	rm -f *.log *.csv

clean-hw:
	rm -fr $(BUILD_DIR) logs

