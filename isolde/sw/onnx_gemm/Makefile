ROOT_DIR            :=  $(shell git rev-parse --show-toplevel)
ONNX_MLIR           ?=  $(ROOT_DIR)/install/onnx-mlir/bin/onnx-mlir
mkfile_path         :=  $(ROOT_DIR)/isolde/sw/onnx_gemm
ONNX_MODEL          := redmule_gemm_24x16x16.onnx
SCRIPTS_DIR         :=  $(ROOT_DIR)/isolde/sw/scripts
LLVM_TARGET_TRIPLE  ?= riscv32-unknown-unknown-elf

# Dimensions
M               := 24
N               := 16
K               := 16
HW_MAX_M        := 12

# Directories
DATA_DIR            := $(mkfile_path)/inc
MODEL_DIR           := $(mkfile_path)/model


.PHONY: golden clean
golden: golden-data golden-model graph


golden-model: $(MODEL_DIR)
	python3 $(SCRIPTS_DIR)/gemm/generate_redmule_gemm.py \
    --m $(M) \
    --n $(N) \
    --k $(K) \
    --hw-max-m $(HW_MAX_M) \
    --dtype f16 \
    --out $(MODEL_DIR)/$(ONNX_MODEL)


golden-data: $(DATA_DIR)
	python3 $(SCRIPTS_DIR)/gemm/gemm_golden.py \
    --m $(M) \
    --n $(N) \
    --k $(K) \
    --seed 1 \
    --out-dir $(DATA_DIR)

graph: $(MODEL_DIR)/$(ONNX_MODEL)
	$(ONNX_MLIR) $(ONNX_MLIR_FLAGS) --mtriple=$(LLVM_TARGET_TRIPLE) --EmitSPADELLVM -o graph $<
	@echo " $(mkfile_path)/graph.ll"

# Ensure that directories exist
$(DATA_DIR):
	@mkdir -p $@

$(MODEL_DIR):
	@mkdir -p $@

clean:
	rm -rf $(DATA_DIR) $(MODEL_DIR)
	rm -f graph*
