ROOT_DIR            :=  $(shell git rev-parse --show-toplevel)
mkfile_path         :=  $(ROOT_DIR)/isolde/system/nxp-ro
PYTHON              ?=  python3


# UART / log viewers and the JTAG case images: radar_attention's own tools.
PORT                ?=  /dev/ttyUSB3
BAUD                ?=  921600


.PHONY: uart-plot



uart-plot:
	$(PYTHON) $(mkfile_path)/tformer_uart_viewer_mod.py --port $(PORT) --baud $(BAUD)

