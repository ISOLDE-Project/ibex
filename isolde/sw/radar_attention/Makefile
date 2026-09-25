.DEFAULT_GOAL := demo
APP_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(APP_DIR)/../../..)
BEAMFORM_DIR := $(abspath $(APP_DIR)/../radar_beamforming)
PYTHON ?= python3
CC ?= clang
SEEDS ?= 5
PORT ?= /dev/ttyUSB3
BAUD ?= 921600
# For a chain-mode log: VIEWER_FLAGS="--weights-name tformer_weights_l1.h"
VIEWER_FLAGS ?=

# The encoder-only build ships two layers; the chained build ships one,
# because two do not fit demo_3's 32 KiB dataram. `make budget` prints why.
LAYERS ?= 2
CHAIN_LAYERS ?= 1

HOST_FLAGS := -std=c11 -O2 -Wall -Wextra -Werror -ffp-contract=off
HOST_INCLUDES := -I$(APP_DIR)/tests/shim -I$(ROOT_DIR)/isolde/system -I$(APP_DIR)

.PHONY: demo data plots model model-chain host-test budget plot uart-plot clean golden

demo: data plots model model-chain

data:
	$(PYTHON) $(APP_DIR)/radar_scene.py --out-dir $(APP_DIR)/results \
	  --header-dir $(APP_DIR)/inc

plots: data
	$(PYTHON) $(APP_DIR)/plot_scenes.py --out-dir $(APP_DIR)/results

model: data
	$(PYTHON) $(APP_DIR)/tformer.py --layers $(LAYERS) --seeds $(SEEDS) \
	  --header-dir $(APP_DIR)/inc --out-dir $(APP_DIR)/results

# Chain mode's export lands in the same inc/ under a different file name:
# the device include path puts inc/ first and cannot be reordered, so the
# firmware selects a configuration with -DTF_WEIGHTS_HEADER, not with -I.
model-chain: data
	$(PYTHON) $(APP_DIR)/tformer.py --layers $(CHAIN_LAYERS) --seeds $(SEEDS) \
	  --header-dir $(APP_DIR)/inc --weights-name tformer_weights_l1.h \
	  --out-dir $(APP_DIR)/results_l1

host-test:
	cd $(APP_DIR) && CC="$(CC)" $(PYTHON) -m unittest discover -s tests -v

# What each configuration would place in dataram, and whether it fits.
budget:
	@for spec in "tformer_weights.h 0 encoder" "tformer_weights.h 1 chain" \
	             "tformer_weights_l1.h 1 chain-1-layer"; do \
	  set -- $$spec; \
	  $(CC) $(HOST_FLAGS) $(HOST_INCLUDES) -I$(APP_DIR)/inc -DTF_CHAIN=$$2 \
	    -DTF_WEIGHTS_HEADER=\"$$1\" \
	    $(APP_DIR)/tests/budget.c -o /tmp/tf_budget_$$3 || exit 1; \
	  echo "=== $$3 ==="; /tmp/tf_budget_$$3; echo; \
	done

# Validate and plot a Verilator log or a captured UART capture.
plot:
	@test -n "$(LOG)" || (echo "Set LOG=/absolute/path/to/tformer.log"; exit 1)
	$(PYTHON) $(APP_DIR)/tformer_viewer.py --log "$(LOG)" \
	  --inc $(APP_DIR)/inc $(VIEWER_FLAGS) \
	  --out-dir $(APP_DIR)/results/from_log

# Read the board directly. Needs pyserial.
uart-plot:
	$(PYTHON) $(APP_DIR)/tformer_uart_viewer.py --port $(PORT) --baud $(BAUD)

golden: data

clean:
	rm -rf $(APP_DIR)/results $(APP_DIR)/results_l1
	rm -rf $(APP_DIR)/inc $(APP_DIR)/__pycache__
