.DEFAULT_GOAL := help
APP_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
SYSTEM_DIR ?= $(abspath $(APP_DIR)/../../system)
SYSTEM_MAKEFILE ?= Makefile.radar-scaling.nodbg
PYTHON ?= python3
HOST_CC ?= cc
PORT ?= /dev/ttyUSB3
BAUD ?= 921600
TIMEOUT ?= 120
OUT_DIR ?= $(APP_DIR)/results/scaling
CAPTURE ?= $(OUT_DIR)/uart.log

.PHONY: help golden host-test bsp-check test-build uart-plot plot clean
help:
	@echo 'golden     regenerate vectors using the original beamforming model'
	@echo 'host-test  check C scheduling, firmware validation and UART parser/plotter'
	@echo 'bsp-check  check C syntax against real BSP headers (host compiler; no RV32 code generation)'
	@echo 'test-build delegate firmware build to isolde/system (full checkout needed)'
	@echo 'uart-plot  capture FPGA UART and create the cycle bar graph'
	@echo 'plot       plot a saved UART log: make plot LOG=/path/to/uart.log'

golden:
	$(PYTHON) $(APP_DIR)/generate_vectors.py

host-test:
	cd $(APP_DIR) && CC="$(HOST_CC)" $(PYTHON) -m unittest discover -s tests -v

# This catches declarations/includes missed by host mocks. GNU C matches the
# production BSP's asm spelling. RV32 defines select firmware code, but this
# remains a frontend-only check, NOT a RISC-V compile or link.
bsp-check:
	$(HOST_CC) -std=gnu11 -ffreestanding -fsyntax-only -Wall -Wextra -Werror \
	  -D__riscv=1 -D__riscv_xlen=32 \
	  -DTINYPRINTF_DEFINE_TFP_PRINTF=1 -DTINYPRINTF_DEFINE_TFP_SPRINTF=0 \
	  -I"$(SYSTEM_DIR)" $(APP_DIR)/main.c

# main.c is the only firmware translation unit. The parent build must select
# the same BSP and platform flags as the original radar_beamforming app.
test-build:
	@test -f "$(SYSTEM_DIR)/$(SYSTEM_MAKEFILE)" || \
	  (echo 'Install the supplied system wrapper in your full Ibex checkout first.'; exit 1)
	$(MAKE) -C "$(SYSTEM_DIR)" -f "$(SYSTEM_MAKEFILE)" TEST=radar_beamforming_scaling test-build

uart-plot:
	$(PYTHON) $(APP_DIR)/plot_cycles.py --port "$(PORT)" --baud "$(BAUD)" \
	  --timeout "$(TIMEOUT)" --capture "$(CAPTURE)" --out-dir "$(OUT_DIR)"

plot:
	@test -n "$(LOG)" || (echo 'Set LOG=/path/to/uart.log'; exit 1)
	$(PYTHON) $(APP_DIR)/plot_cycles.py --log "$(LOG)" --out-dir "$(OUT_DIR)"

clean:
	rm -rf "$(APP_DIR)/results"
