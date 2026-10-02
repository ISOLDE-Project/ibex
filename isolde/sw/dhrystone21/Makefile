ROOT_DIR            :=  $(shell git rev-parse --show-toplevel)
mkfile_path         :=  $(ROOT_DIR)/isolde/sw/dhrystone21
PYTHON              ?=  python3


# UART / log viewers and the JTAG case images: radar_attention's own tools.
PORT                ?=  /dev/ttyUSB3
BAUD                ?=  921600
VIEWER_FLAGS        ?=

.DELETE_ON_ERROR:
.PHONY:  uart-plot 

##
uart-plot:
	$(PYTHON) $(mkfile_path)/dhry_uart_viewer.py --port $(PORT) --baud $(BAUD) 


#