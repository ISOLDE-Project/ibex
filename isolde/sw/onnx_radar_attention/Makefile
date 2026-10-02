ROOT_DIR            :=  $(shell git rev-parse --show-toplevel)
ONNX_MLIR           ?=  $(ROOT_DIR)/install/onnx-mlir/bin/onnx-mlir
mkfile_path         :=  $(ROOT_DIR)/isolde/sw/onnx_radar_attention
LLVM_TARGET_TRIPLE  ?=  riscv32-unknown-unknown-elf
PYTHON              ?=  python3

# Directories
DATA_DIR            :=  $(mkfile_path)/inc
MODEL_DIR           :=  $(mkfile_path)/models
HOST_DIR            :=  $(mkfile_path)/build-host
ONNX_MODEL          :=  $(MODEL_DIR)/tformer_encoder.onnx

# The radar_attention export to compile: weights, case and goldens.
# `make model` in radar_attention writes it (needs torch).
RADAR_DIR           ?=  $(ROOT_DIR)/isolde/sw/radar_attention
RADAR_INC           ?=  $(RADAR_DIR)/inc
WEIGHTS_NAME        ?=  tformer_weights.h
EXPORT              :=  $(RADAR_INC)/$(WEIGHTS_NAME) $(RADAR_INC)/tformer_vectors.h

# UART / log viewers and the JTAG case images: radar_attention's own tools.
PORT                ?=  /dev/ttyUSB3
BAUD                ?=  921600
VIEWER_FLAGS        ?=
CASES               ?=  static receding crossing

HOST_CC             ?=  clang
HOST_CFLAGS         :=  -std=c11 -O2 -Wall -Wextra -ffp-contract=off \
                        -I$(mkfile_path)/tests/shim -I$(ROOT_DIR)/isolde/system \
                        -I$(HOST_DIR) -I$(DATA_DIR)

.DELETE_ON_ERROR:
.PHONY: golden model graph host-test sim plot uart-plot cases clean

## models/tformer_encoder.onnx, inc/*.h and graph.ll
golden: model graph
golden-clean: clean

## the ONNX encoder and inc/tformer_config.h, inc/tformer_vectors.h
model: $(ONNX_MODEL)

$(ONNX_MODEL): $(mkfile_path)/onnx_radar_model.py $(mkfile_path)/tformer_onnx.py \
               $(EXPORT)
	$(PYTHON) $< --radar-inc $(RADAR_INC) --weights-name $(WEIGHTS_NAME) \
	  --out $@ --header-dir $(DATA_DIR)

$(EXPORT):
	@echo "$@ not found: run \`make model\` in $(RADAR_DIR) first" && false

## graph.ll next to this Makefile (picked up by the system test-build) and
## inc/graph_info.h (tiles, launches and waits of the schedule, for main.c)
graph: $(mkfile_path)/graph.ll $(DATA_DIR)/graph_info.h

$(mkfile_path)/graph.ll: $(ONNX_MODEL)
	$(ONNX_MLIR) $(ONNX_MLIR_FLAGS) --mtriple=$(LLVM_TARGET_TRIPLE) \
	  --EmitSPADELLVM -o $(mkfile_path)/graph $<
	@rm -f $(mkfile_path)/graph.o
	@echo "🔔 $@"

$(DATA_DIR)/graph_info.h: $(mkfile_path)/graph.ll $(mkfile_path)/graph_info.py
	$(PYTHON) $(mkfile_path)/graph_info.py $< $@

## main.c + the graph on the host, against the SPM model (not RTL)
host-test: $(ONNX_MODEL)
	@mkdir -p $(HOST_DIR)
	$(ONNX_MLIR) $(ONNX_MLIR_FLAGS) --EmitSPADELLVM -o $(HOST_DIR)/graph $<
	$(PYTHON) $(mkfile_path)/graph_info.py $(HOST_DIR)/graph.ll \
	  $(HOST_DIR)/graph_info.h
	$(HOST_CC) $(HOST_CFLAGS) -o $(HOST_DIR)/onnx_radar_attention \
	  $(mkfile_path)/main.c $(HOST_DIR)/graph.ll $(mkfile_path)/tests/host_runtime.c
	$(HOST_DIR)/onnx_radar_attention | tee $(HOST_DIR)/uart.log | grep -v '^\[TFWIN\]'

## firmware build + aida_tb RTL run (verilate once first, see README.md)
sim: graph
	$(MAKE) -C $(ROOT_DIR)/isolde/system -f Makefile.onnx-radar-attention.nodbg \
	  test-clean test-build veri-run

## validate and plot a Verilator log or a UART capture (LOG=/abs/path)
plot:
	@test -n "$(LOG)" || (echo "Set LOG=/absolute/path/to/tformer.log"; exit 1)
	$(PYTHON) $(RADAR_DIR)/tformer_viewer.py --log "$(LOG)" \
	  --inc $(RADAR_INC) $(VIEWER_FLAGS) --out-dir $(mkfile_path)/results/from_log

## the live viewer on the board's UART, with the ONNX model next to it
## (needs pyserial; NETRON=1 also opens the model in Netron, pip install netron)
NETRON              ?=  0
ONNX_VIEWER_FLAGS   :=  --model $(ONNX_MODEL) $(if $(filter 1,$(NETRON)),--netron)
uart-plot: $(ONNX_MODEL)
	$(PYTHON) $(mkfile_path)/onnx_uart_viewer.py --port $(PORT) --baud $(BAUD) \
	  $(ONNX_VIEWER_FLAGS)

## the same window, replaying a captured UART / Verilator log (LOG=/abs/path)
replay: $(ONNX_MODEL)
	@test -n "$(LOG)" || (echo "Set LOG=/absolute/path/to/uart.log"; exit 1)
	$(PYTHON) $(mkfile_path)/onnx_uart_viewer.py --replay "$(LOG)" \
	  $(ONNX_VIEWER_FLAGS)

## radar_attention's own live viewer, unchanged
uart-plot-classic:
	$(PYTHON) $(RADAR_DIR)/tformer_uart_viewer.py --port $(PORT) --baud $(BAUD)

## the model alone in Netron (pip install netron)
netron: $(ONNX_MODEL)
	$(PYTHON) -c "import sys, netron; sys.argv = ['netron', '$(ONNX_MODEL)']; netron.main()"

## one ihex per class for `upload onnx_radar_attention <class>` (needs a
## test-build first: the addresses come from its readelf listing)
cases:
	$(PYTHON) $(mkfile_path)/onnx_radar_case.py --classes $(CASES) \
	  --weights $(RADAR_INC)/$(WEIGHTS_NAME) \
	  --bin $(ROOT_DIR)/isolde/system/sw/bin \
	  --out $(ROOT_DIR)/isolde/system/app-images

clean:
	rm -rf $(DATA_DIR) $(MODEL_DIR) $(HOST_DIR) $(mkfile_path)/results
	rm -rf $(mkfile_path)/__pycache__
	rm -f $(mkfile_path)/graph.* $(mkfile_path)/MemManager.yaml
