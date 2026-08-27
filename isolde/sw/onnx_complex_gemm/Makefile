ROOT_DIR            :=  $(shell git rev-parse --show-toplevel)
ONNX_MLIR           ?=  $(ROOT_DIR)/install/onnx-mlir/bin/onnx-mlir
mkfile_path         :=  $(ROOT_DIR)/isolde/sw/onnx_complex_gemm
ONNX_MODEL          := redmule_complex_gemm_12x16x16.onnx
SCRIPTS_DIR         :=  $(ROOT_DIR)/isolde/sw/scripts

# Directories
DATA_DIR            := $(mkfile_path)/inc
MODEL_DIR          := $(mkfile_path)/model
#



.PHONY: golden  clean
golden: golden-data golden-model graph


golden-model: $(MODEL_DIR)
	python3 $(SCRIPTS_DIR)/complex_gemm/generate_redmule_complex_gemm.py \
    --m 12 \
    --n 16 \
    --k 16 \
    --dtype f16 \
    --out $(MODEL_DIR)/redmule_complex_gemm_12x16x16.onnx
  

golden-data: $(DATA_DIR)
	python3 $(SCRIPTS_DIR)/complex_gemm/complex_gemm.py\
    --m 12 \
    --n 16 \
    --k 16 \
    --tile-m 12 \
    --tile-n 16 \
    --tile-k 16 \
    --seed 1 \
    --out-dir ./inc

graph:  $(MODEL_DIR)/$(ONNX_MODEL) 	
	$(ONNX_MLIR) $(ONNX_MLIR_FLAGS) --mtriple=riscv32-unknown-elf --EmitSPADELLVM -o graph  $<
	@echo "🔔 $(mkfile_path)/graph.ll"

# Ensure that directories exists
$(DATA_DIR):
	@mkdir -p $@

$(MODEL_DIR):
	@mkdir -p $@
	
clean:
	rm -rf $(DATA_DIR) $(MODEL_DIR)
	rm -f graph*