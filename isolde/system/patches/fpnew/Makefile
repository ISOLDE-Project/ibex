
PATCH_DST_DIR := $(ROOT_DIR)/isolde/system/.bender/git/checkouts/fpnew-8ce10fc9208d86ea
PATCH_SRC_DIR := $(ROOT_DIR)/isolde/system/patches/fpnew
THE_PATCH     := fpnew_top.sv.patch

$(PATCH_DST_DIR)/$(THE_PATCH): $(PATCH_SRC_DIR)/$(THE_PATCH)
	cp $< $@
	cd $(PATCH_DST_DIR) && git apply $(THE_PATCH)

.PHONY: all
all: $(PATCH_DST_DIR)/$(THE_PATCH)