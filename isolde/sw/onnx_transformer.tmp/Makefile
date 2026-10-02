ROOT_DIR            :=  $(shell git rev-parse --show-toplevel)
ONNX_MLIR           ?=  $(ROOT_DIR)/install/onnx-mlir/bin/onnx-mlir
mkfile_path         :=  $(ROOT_DIR)/isolde/sw/onnx_transformer
ONNX_MODEL          :=  transformer_layer.onnx
LLVM_TARGET_TRIPLE  ?=  riscv32-unknown-unknown-elf
PYTHON              ?=  python3

# Directories
DATA_DIR            :=  $(mkfile_path)/inc
MODEL_DIR           :=  $(mkfile_path)/models
HOST_DIR            :=  $(mkfile_path)/build-host

# Weights and window of the test:
#   SOURCE=random    random weights and window from SEED (default)
#   SOURCE=firmware  the trained encoder (radar_attention/inc_l1): tf_proj,
#                    tf_pos, the tf_features window; the golden is checked
#                    against the firmware's tf_golden_proj
SOURCE              ?=  random
SEED                ?=  0
RADAR_INC           ?=  $(ROOT_DIR)/isolde/sw/radar_attention/inc_l1
ifeq ($(SOURCE),firmware)
PROJ_FLAGS          ?=  --weights $(RADAR_INC)/tformer_weights.h \
                        --vectors $(RADAR_INC)/tformer_vectors.h
else ifeq ($(SOURCE),random)
PROJ_FLAGS          ?=  --seed $(SEED)
else
$(error SOURCE must be random or firmware)
endif

# Host smoke test: graph built for the host, run against tests/host_runtime.c
# (an SPM + RedMulE model of onnx_redmule_runtime, not RTL).
HOST_CC             ?=  clang
HOST_CFLAGS         :=  -std=c11 -O2 -Wall -ffp-contract=off \
                        -I$(mkfile_path)/tests/shim -I$(ROOT_DIR)/isolde/system \
                        -I$(DATA_DIR)

.PHONY: golden golden-model golden-data graph host-test sim clean

## models/proj.onnx, inc/*.h and graph.ll
golden: golden-model graph

## models/proj.onnx and, from the same weights, the test data in inc/
golden-model golden-data: $(MODEL_DIR)/$(ONNX_MODEL)

$(MODEL_DIR)/$(ONNX_MODEL): $(mkfile_path)/generate_transformer.py | $(MODEL_DIR) $(DATA_DIR)
 	$(PYTHON) $< $(PROJ_FLAGS) --out $@ --header-dir $(DATA_DIR)
	

## graph.ll next to this Makefile (picked up by the system test-build)
graph: $(mkfile_path)/graph.ll

$(mkfile_path)/graph.ll: $(MODEL_DIR)/$(ONNX_MODEL)
	$(ONNX_MLIR) $(ONNX_MLIR_FLAGS) --mtriple=$(LLVM_TARGET_TRIPLE) \
	  --EmitSPADELLVM -o $(mkfile_path)/graph $<
	@rm -f $(mkfile_path)/graph.o
	@echo "🔔 $@"

## main.c + the graph on the host, against the SPM model
host-test: $(MODEL_DIR)/$(ONNX_MODEL)
	@mkdir -p $(HOST_DIR)
	$(ONNX_MLIR) $(ONNX_MLIR_FLAGS) --EmitSPADELLVM -o $(HOST_DIR)/graph $<
	$(HOST_CC) $(HOST_CFLAGS) -o $(HOST_DIR)/onnx_tiling_gemm \
	  $(mkfile_path)/main.c $(HOST_DIR)/graph.ll \
	  $(mkfile_path)/tests/host_runtime.c $(ROOT_DIR)/isolde/system/bsp/fp16_utils.c
	$(HOST_DIR)/onnx_tiling_gemm

## firmware build + aida_tb RTL run (verilate once first, see README.md)
sim: $(mkfile_path)/graph.ll
	$(MAKE) -C $(ROOT_DIR)/isolde/system -f Makefile.onnx-tiling-gemm.nodbg \
	  test-clean test-build veri-run

# Ensure that directories exist
$(DATA_DIR) $(MODEL_DIR):
	@mkdir -p $@

clean:
	rm -rf $(DATA_DIR) $(MODEL_DIR) $(HOST_DIR)
	rm -f $(mkfile_path)/graph* $(mkfile_path)/MemManager.yaml
