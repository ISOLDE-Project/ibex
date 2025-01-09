#!/bin/bash

# Iterate i from 0 to 10
for i in {0..10}; do
  echo "Running test with IMEM_LATENCY=$i"
  make -C tca_system IMEM_LATENCY=$i verilate test-clean  sim-input TEST_CFLAGS=-DCUSTOM_128B veri-run
  # Check if the command succeeded
  if [ $? -ne 0 ]; then
    echo "Error: make failed for IMEM_LATENCY=$i"
    exit 1
  fi
done

echo "All runs completed successfully!"
