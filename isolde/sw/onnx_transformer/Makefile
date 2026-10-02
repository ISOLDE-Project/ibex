ROOT_DIR            :=  $(shell git rev-parse --show-toplevel)
ONNX_MLIR           ?=  $(ROOT_DIR)/install/onnx-mlir/bin/onnx-mlir
mkfile_path         :=  $(ROOT_DIR)/isolde/sw/onnx_transformer
LLVM_TARGET_TRIPLE  ?=  riscv32-unknown-unknown-elf
PYTHON              ?=  python3

# Directories
DATA_DIR            :=  $(mkfile_path)/inc
MODEL_DIR           :=  $(mkfile_path)/models
HOST_DIR            :=  $(mkfile_path)/build-host
ONNX_MODEL          :=  $(MODEL_DIR)/transformer.onnx

# The block under test (transformer_app.py --block):
#   layer       EncoderLayer: h + MHA(h), then + FFN (default)
#   mha         h + MultiHeadAttention(h, h)
#   ffn         h + PositionwiseFeedForward(h)
#   proj        window[12,32] . Wproj + P
#   proj_layer  proj, then EncoderLayer
BLOCK               ?=  layer

# Weights and input of the test:
#   SOURCE=random    random weights and input from SEED (default), d_ff D_FF
#   SOURCE=firmware  layer 0 of the trained encoder (radar_attention/inc_l1);
#                    the input is the firmware's value at the block's entry
#                    and the golden must equal its value at the exit
#                    (tf_golden_proj / _l0_attn_out / _l0_out), else stop
SOURCE              ?=  random
SEED                ?=  0
D_FF                ?=  48
RADAR_INC           ?=  $(ROOT_DIR)/isolde/sw/radar_attention/inc_l1
ifeq ($(SOURCE),firmware)
TRANSFORMER_FLAGS   ?=  --weights $(RADAR_INC)/tformer_weights.h \
                        --vectors $(RADAR_INC)/tformer_vectors.h
else ifeq ($(SOURCE),random)
TRANSFORMER_FLAGS   ?=  --seed $(SEED) --d-ff $(D_FF)
else
$(error SOURCE must be random or firmware)
endif

# The model, inc/ and graph.ll are rebuilt when the configuration changes.
CONFIG              :=  --block $(BLOCK) $(TRANSFORMER_FLAGS)
CONFIG_STAMP        :=  $(MODEL_DIR)/config.txt
ifeq ($(filter clean,$(MAKECMDGOALS)),)
$(shell mkdir -p $(MODEL_DIR); \
  [ "`cat $(CONFIG_STAMP) 2>/dev/null`" = "$(CONFIG)" ] || \
  echo "$(CONFIG)" > $(CONFIG_STAMP))
endif
$(CONFIG_STAMP): | $(MODEL_DIR)
	echo "$(CONFIG)" > $@

# Host smoke test: graph built for the host, run against tests/host_runtime.c
# (an SPM + RedMulE model of onnx_redmule_runtime, not RTL).
HOST_CC             ?=  clang
HOST_CFLAGS         :=  -std=c11 -O2 -Wall -ffp-contract=off \
                        -I$(mkfile_path)/tests/shim -I$(ROOT_DIR)/isolde/system \
                        -I$(HOST_DIR) -I$(DATA_DIR)

.DELETE_ON_ERROR:
.PHONY: golden golden-model golden-data graph host-test sim clean

## models/transformer.onnx, inc/*.h and graph.ll
golden: golden-model graph
golden-clean: clean

## models/transformer.onnx and, from the same weights, the test data in inc/
golden-model golden-data: $(ONNX_MODEL)

$(ONNX_MODEL): $(mkfile_path)/transformer_app.py \
               $(mkfile_path)/generate_transformer.py $(CONFIG_STAMP) \
               | $(DATA_DIR)
	$(PYTHON) $< $(CONFIG) --out $@ --header-dir $(DATA_DIR)

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

## main.c + the graph on the host, against the SPM model
host-test: $(ONNX_MODEL)
	@mkdir -p $(HOST_DIR)
	$(ONNX_MLIR) $(ONNX_MLIR_FLAGS) --EmitSPADELLVM -o $(HOST_DIR)/graph $<
	$(PYTHON) $(mkfile_path)/graph_info.py $(HOST_DIR)/graph.ll \
	  $(HOST_DIR)/graph_info.h
	$(HOST_CC) $(HOST_CFLAGS) -o $(HOST_DIR)/onnx_transformer \
	  $(mkfile_path)/main.c $(HOST_DIR)/graph.ll \
	  $(mkfile_path)/tests/host_runtime.c $(ROOT_DIR)/isolde/system/bsp/fp16_utils.c
	$(HOST_DIR)/onnx_transformer

## firmware build + aida_tb RTL run (verilate once first, see README.md)
sim: graph
	$(MAKE) -C $(ROOT_DIR)/isolde/system -f Makefile.nodbg \
	  test-clean test-build veri-run

# Ensure that directories exist
$(DATA_DIR) $(MODEL_DIR):
	@mkdir -p $@

clean:
	rm -rf $(DATA_DIR) $(MODEL_DIR) $(HOST_DIR)
	rm -f $(mkfile_path)/graph.* $(mkfile_path)/MemManager.yaml
