ROOT_DIR            :=  $(shell git rev-parse --show-toplevel)
mkfile_path         :=  $(ROOT_DIR)/isolde/sw/gemm_tiled


golden: $(DST_DIR)
	python3 $(mkfile_path)/golden-model/gemm_sw_tiling.py \
    --m 24 \
    --n 32 \
    --k 32 \
    --tile-m 12 \
    --tile-n 16 \
    --tile-k 16 \
    --seed 1 \
    --out-dir ./inc





# Directories
DST_DIR          := $(mkfile_path)/inc
# Full paths to source and destination files

# Ensure the destination directory exists
$(DST_DIR):
	@mkdir -p $@


.PHONY:  clean	
clean:
	rm -rf $(DST_DIR) 

	