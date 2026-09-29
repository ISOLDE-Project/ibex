# ONNX complex GEMM firmware test

This project runs the generated `graph.ll` as bare-metal Ibex firmware and
checks its split-complex FP16 result against the same two-phase RedMulE golden
model as `isolde/sw/complex_gemm`.

The checked-in test vectors are fixed at:

- `A`: `12 x 16` complex FP16
- `B`: `16 x 16` complex FP16
- `C`: `12 x 16` complex FP16
- random seed: `1`
- accepted error: at most 2 FP16 ULP

## Prerequisites

Apply the AISMEM-to-LLVM milestone first. In particular, the following BSP
files must exist:

```text
isolde/system/bsp/onnx_redmule_runtime.c
isolde/system/bsp/onnx_redmule_runtime.h
```

The host Python environment also needs the `intelhex` package used by the
repository's existing `hex_fragment.py` utility.

## Place graph.ll

Copy the LLVM IR produced by onnx-mlir into this directory:

```bash
cp /path/to/generated/graph.ll ibex/isolde/sw/onnx_complex_gemm/graph.ll
```

The expected graph ABI is:

```c
typedef struct { void *cr; void *ci; } graph_outputs_t;
graph_outputs_t main_graph(const void *ar, const void *ai,
                           const void *br, const void *bi);
```

## Configure and build

Point `RISCV_LLVM_ROOT` at the same RISC-V LLVM installation used by the
onnx-mlir build:

```bash
cd ibex/isolde/sw/onnx_complex_gemm

export RISCV_LLVM_ROOT=/home/dan/ibex/.task5.2/git/checkouts/toolchain/onnx-mlir/install/riscv-llvm

cmake -S . -B build \
  -DCMAKE_TOOLCHAIN_FILE=cmake/riscv32-clang-toolchain.cmake

cmake --build build --parallel
```

## Repository-native make flow

The shared BSP build has been extended to compile test-local `.ll` files. This
means the project also follows the same flow as the other `isolde/sw` tests.
From the Ibex repository root:

```bash
. ./eth.sh
cd isolde/system
make -f Makefile.onnx-complex.nodbg test-clean test-build
```

Equivalently, without the wrapper Makefile:

```bash
make DBG_MODULE=0 \
  ENABLE_SPM=1 \
  VLT_TOP_MODULE=aida_tb \
  BENDER_EXTRA_TARGET="-t fpga_sim -D REDMULE_CLUSTER" \
  TEST=onnx_complex_gemm \
  test-clean test-build
```

This discovers both `main.c` and `graph.ll`, compiles them with the configured
RISC-V Clang, links the BSP runtime, and generates the usual files beneath
`isolde/system/sw/bin`.

The CMake project exposes wrappers for the same commands:

```bash
cmake --build build --target test-clean
cmake --build build --target test-build

# Or perform both in one target:
cmake --build build --target system-flow
```

To keep `graph.ll` elsewhere, configure with:

```bash
cmake -S . -B build \
  -DCMAKE_TOOLCHAIN_FILE=cmake/riscv32-clang-toolchain.cmake \
  -DGRAPH_LL=/absolute/path/to/graph.ll
```

The build produces:

```text
build/graph.o
build/onnx_complex_gemm.elf
build/onnx_complex_gemm.map
build/onnx_complex_gemm.objdump
build/onnx_complex_gemm-m.hex
build/onnx_complex_gemm-d.hex
```

`_reserveMemory(1)` and `_reserveMemory(2)` are implemented by the harness as
two aligned 384-byte result buffers. The firmware calls `main_graph`, checks
`Cr` and `Ci`, prints `[ONNX-CGEMM] PASSED`, and returns zero on success.

## Run with aida_tb

Build the two-tile RedMulE Verilator model once from `ibex/isolde/system`:

```bash
cd ibex/isolde/system

make DBG_MODULE=0 \
  ENABLE_SPM=1 \
  VLT_TOP_MODULE=aida_tb \
  BENDER_EXTRA_TARGET="-t fpga_sim -D REDMULE_CLUSTER" \
  verilate
```

Then return to the project and run:

```bash
cd ../sw/onnx_complex_gemm
cmake --build build --target run
```

If the simulator executable is elsewhere, set it while configuring:

```bash
cmake -S . -B build \
  -DCMAKE_TOOLCHAIN_FILE=cmake/riscv32-clang-toolchain.cmake \
  -DAIDA_SIM=/absolute/path/to/verilator_executable
```

Successful execution ends with:

```text
[ONNX-CGEMM] PASSED
[FPGA SIM] Success
```

## Regenerate test vectors

The data was generated from the existing reference script:

```bash
python3 ../complex_gemm/golden-model/complex_gemm.py \
  --m 12 --n 16 --k 16 \
  --tile-m 12 --tile-n 16 --tile-k 16 \
  --seed 1 --out-dir ./inc
```
