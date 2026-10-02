.DEFAULT_GOAL := demo
APP_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(APP_DIR)/../../..)
PYTHON ?= python3
CC ?= cc
ONNX_MLIR ?= $(ROOT_DIR)/install/onnx-mlir/bin/onnx-mlir
ONNX_MLIR_FLAGS ?=

.PHONY: demo golden model graph host-test plot clean uart-test uart-plot check-conda-ibex

check-conda-ibex:
	@if [ "$$CONDA_DEFAULT_ENV" != "ibex" ]; then \
		echo "Error: Conda environment 'ibex' must be active."; \
		echo 'Run: source "$$HOME/miniconda3/etc/profile.d/conda.sh" && conda activate ibex'; \
		exit 1; \
	fi

demo:
	$(PYTHON) $(APP_DIR)/beamforming.py --out-dir $(APP_DIR)/results \
	  --header $(APP_DIR)/inc/radar_vectors.h --onnx-dir $(APP_DIR)/model --animate

golden: demo

model:
	$(PYTHON) $(APP_DIR)/beamforming.py --out-dir $(APP_DIR)/results \
	  --onnx-dir $(APP_DIR)/model

graph: model
	$(ONNX_MLIR) $(ONNX_MLIR_FLAGS) --mtriple=riscv32-unknown-unknown-elf \
	  --EmitSPADELLVM -o $(APP_DIR)/graph $(APP_DIR)/model/radar_block_f16.onnx
	@test -s $(APP_DIR)/graph.ll
	@echo "Inspect graph.ll: main_graph, allocation IDs 1/2, omrm_* calls on tiles 0/1."

host-test:
	cd $(APP_DIR) && CC="$(CC)" $(PYTHON) -m unittest discover -s tests -v

uart-test:
	cd $(APP_DIR) && $(PYTHON) -m unittest discover -s tests -p 'test_uart_viewer.py' -v

uart-plot: check-conda-ibex
	python uart_viewer.py --port /dev/ttyUSB3 --baud 921600 \
                          --capture results/uart_capture.log --gif results/uart_sweep.gif
plot:
	@test -n "$(LOG)" || (echo "Set LOG=/absolute/path/to/verilator.log"; exit 1)
	$(PYTHON) $(APP_DIR)/beamforming.py --rtl-log "$(LOG)" --out-dir $(APP_DIR)/results/from_log

clean:
	rm -rf $(APP_DIR)/results
	rm -f $(APP_DIR)/graph.ll $(APP_DIR)/graph.o $(APP_DIR)/graph.onnx.mlir
	rm -f $(APP_DIR)/model/*.onnx
