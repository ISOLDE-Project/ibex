.PHONY: bender-clean rtl-update bender-packages
## clean .bender directory
bender-clean:
	@echo "Cleaning Bender project..."
	$(BENDER) clean --all
# 	rm -rf  Bender.lock
	@echo "Bender project cleaned."

## update the rtl code base
bender-update:	bender-clean
	git submodule update --init
	$(BENDER) update
	# === apply patch(es) ===
	make -C $(mkfile_path)/patches/fpnew

## bender packages hierarchy
bender-pkg:
	$(BENDER) packages
