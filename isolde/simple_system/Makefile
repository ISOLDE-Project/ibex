ROOT_DIR            :=  $(shell git rev-parse --show-toplevel)
IBEX_CONFIG         ?=  isolde
FUSESOC_CONFIG_OPTS := $(shell cd $(ROOT_DIR) && $(ROOT_DIR)/util/ibex_config.py $(IBEX_CONFIG) fusesoc_opts)
TEST                ?= vlinstr_test
test-program        ?= $(ROOT_DIR)/isolde/sw/simple_system/$(TEST)/$(TEST).elf
BUILD_DIR           := build/$(IBEX_CONFIG)
SYNTH_DIR           := synth/$(IBEX_CONFIG)
TMP_DIR             := tmp/$(IBEX_CONFIG)

num_cores := $(shell nproc)
num_cores_half := $(shell echo "$$(($(num_cores) / 2))")

build-hw:
	fusesoc --cores-root=$(ROOT_DIR) run --target=sim --setup --build  --build-root=$(BUILD_DIR) isolde:ibex:ibex_simple_system $(FUSESOC_CONFIG_OPTS)

flist: ibex_manifest.flist
	mv $(TMP_DIR)/sim-verilator/isolde_ibex_ibex_simple_system_0.vc . 
	rm -fr $(TMP_DIR)
	@echo $(CURDIR)/isolde_ibex_ibex_simple_system_0.vc done

ibex_manifest.flist:
#	fusesoc --cores-root=$(ROOT_DIR) run --target=lint  --no-export  --build-root=./flist isolde:ibex:ibex_simple_system $(FUSESOC_CONFIG_OPTS) 
	fusesoc --cores-root=$(ROOT_DIR) run --target=sim --setup --no-export --build-root=$(TMP_DIR) isolde:ibex:ibex_simple_system $(FUSESOC_CONFIG_OPTS)

synth-setup:
	mkdir -p $(SYNTH_DIR)
	fusesoc --cores-root=$(ROOT_DIR) run --target=synth --setup  --no-export --build-root=$(SYNTH_DIR) isolde:ibex:ibex_simple_system $(FUSESOC_CONFIG_OPTS)

.PHONY: synth
synth: synth-setup
	cd ./synth/isolde/synth-vivado && \
	echo "launch_runs synth_1 " >launch_runs.tcl && \
	echo "wait_on_runs synth_1" >>launch_runs.tcl && \
	vivado -mode batch -source ./isolde_ibex_ibex_simple_system_0.tcl ./launch_runs.tcl | tee vivado.log

	

.PHONY: test-program $(test-program) clean
# Rule for test-program
$(test-program):
	make -C $(dir $@)

test-app: $(test-program)

clean-test:
	make -C $(dir $(test-program)) clean

run-test:
	@rm -f ibex_simple_system.log
	@rm -f trace_core_00000000.log
	./$(BUILD_DIR)/sim-verilator/Vibex_simple_system -t --meminit=ram,$(test-program)
	@echo
	@echo ibex_simple_system.log
	@echo ======================
	@cat ibex_simple_system.log
	@echo ======================
	@echo isolde_exec_block.log

clean:
#	rm -f $(test-program)
	make -C $(dir $(test-program)) clean
	rm -fr $(BUILD_DIR) logs
	rm -f *.log *.csv

clean-hw:
	rm -fr $(BUILD_DIR) logs

view-log:
	/home/dan/ext/gtkwave-src/install/bin/gtkwave  $(ROOT_DIR)/isolde/simple_system/logs/ibex.vcd --script=$(ROOT_DIR)/isolde/simple_system/load_waveform.tcl


veri-test: 
	make -C $(dir $(test-program)) clean
	make -C $(dir $(test-program)) 	
	@rm -f ibex_simple_system.log
	@rm -f trace_core_00000000.log
	./$(BUILD_DIR)/sim-verilator/Vibex_simple_system -t --meminit=ram,$(test-program)
	@echo
	@echo ibex_simple_system.log
	@echo ======================
	@cat ibex_simple_system.log
	@echo ======================
	@echo isolde_exec_block.log

clean-test-programs: 
	find $(ROOT_DIR)/isolde/sw/simple_system -name "*.o"       -delete
	find $(ROOT_DIR)/isolde/sw/simple_system -name "*.hex"     -delete
	find $(ROOT_DIR)/isolde/sw/simple_system -name "*.elf"     -delete
	find $(ROOT_DIR)/isolde/sw/simple_system -name "*.map"     -delete
	find $(ROOT_DIR)/isolde/sw/simple_system -name "*.readelf" -delete
	find $(ROOT_DIR)/isolde/sw/simple_system -name "*.objdump" -delete
	find $(ROOT_DIR)/isolde/sw/simple_system -name "*.headers" -delete
	find $(ROOT_DIR)/isolde/sw/simple_system -name "corev_*.S" -delete
	find $(ROOT_DIR)/isolde/sw/simple_system -name "*.itb" -delete
	find $(ROOT_DIR)/isolde/sw/simple_system -name "*.d" -delete