.PHONY: uart-plot fpga-flash

uart-plot:
	make -C $(TEST_SRC_DIR) $@

fpga-flash:
	make -C $(mkfile_path)/fpga flash