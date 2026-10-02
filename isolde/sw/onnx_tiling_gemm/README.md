# ONNX tiling GEMM firmware test

Validates onnx-mlir's RedMulE Gemm tiling against the RTL, like
`onnx_complex_gemm` does for the split-complex GEMM.  The model is the
radar_attention projection

```text
h[12,16] = window[12,32] . tf_proj[32,16] + tf_pos[12,16]     (MatMul + Add)
```

onnx-mlir fuses MatMul + Add into one `onnx.Gemm`, and `aisle-tile` splits
it into two native RedMulE launches, K-tiled:

| graph.ll (`main_graph`) | firmware equivalent (`tformer_runtime3`) |
|---|---|
| upload `window[:, 0:16]` into X, `tf_pos` into Y; GEMM, wait | `launch_bias(0, window, tf_proj, tf_pos)` |
| upload `window[:, 16:32]` into X; GEMM into the same Y, wait | `launch_accumulate(0, window + 192, tf_proj + 256)` |
| download Y into `_reserveMemory(1)` | `collect(0, h)` |

`tf_proj` is split at compile time into two 16x16 constants, uploaded once
by `main_graph_preload()` and resident in SPM (rows 0-31 of tile 0).

## Prerequisites

* onnx-mlir with the ISOLDE patches 0004-0007 (check:
  `strings $(ONNX_MLIR) | grep -c aisle-tile` prints 1).
* This repository with `omrm_upload_tile_f16` in
  `isolde/system/bsp/onnx_redmule_runtime.c` (patch
  "bsp: add omrm_upload_tile_f16"), which `graph.ll` calls.
* Python: `numpy`, `onnx` (`onnxruntime` only for `--verify`).

## Build the test data and graph.ll

```bash
. ./torch.sh
cd isolde/system
make TEST=onnx_tiling_gemm golden                    # models/proj.onnx, inc/*.h, graph.ll
```

One `proj_onnx.py` run writes the model and, from the same weights, the
data `main.c` needs:

| file | contents |
|---|---|
| `models/proj.onnx` | the graph; `tf_proj`, `tf_pos` are initializers |
| `inc/proj_window.h` | `window_inp[384]`, the input, row-major `[12][32]` |
| `inc/proj_golden.h` | `h_golden[192]`, bit-exact RedMulE FP16 result |
| `inc/tensor_dim.h` | `FRAMES`, `FEATURES`, `D_MODEL` |

`SOURCE=random` (default) uses `SEED` (default 0); `SOURCE=firmware` takes
`tf_proj`, `tf_pos` and the `tf_features` window from
`radar_attention/inc_l1` and stops if the golden differs from the firmware's
`tf_golden_proj`.  `PROJ_FLAGS` passes anything else to the script.

The golden uses the RedMulE arithmetic of `radar_attention/tformer.py`
(FP16 rounding after each of the 16 reduction steps) in the order the graph
runs: `Y = pos`, K-tile 0, K-tile 1.

**Keep the model, the data and graph.ll together**: `graph.ll` embeds the
weights, `inc/` the matching golden.  `make golden` rebuilds all of them
when `proj_onnx.py` changes; after changing `SOURCE`/`SEED`, run
`make clean golden`.

## Host smoke test

```bash
make host-test
```

Compiles `main.c` with a host build of the graph and
`tests/host_runtime.c` -- a model of the tile-private SPMs (64-byte rows) and
of the RedMulE arithmetic, where a GEMM is only computed at its
`omrm_wait` -- and runs it.  It checks the ABI, the schedule and the data
before an RTL run; it is not an RTL simulation.

## RTL run on aida_tb

From `isolde/system` (`. ./eth.sh` first):

```bash
make -f Makefile.nodbg veri-clean verilate                  # once
make -f Makefile.nodbg TEST=onnx_tiling_gemm test-clean test-build veri-run
```

or `make sim` from this directory for the second line.  `test-build`
compiles every `*.c` / `*.ll` at the top of this directory (`main.c`,
`graph.ll`; not `tests/`, not `build-host/`) with `inc/` on the include path
and links the BSP runtime.  Success ends with:

```text
[ONNX-TGEMM] errors=0 worst_ulp=0 allowed_ulp=0
[ONNX-TGEMM] PASSED
```

## What main.c checks

* `main_graph_preload()` once, then `main_graph(window_inp)` twice; the
  second run fails if the first overwrote the resident weights.
* The result buffer is filled with NaN before each run and must be the one
  `_reserveMemory(1)` handed out.
* Every value must equal `h_golden` bit for bit (`worst_ulp == 0`); build
  with `TEST_CPPFLAGS=-DPROJ_ALLOWED_ULP=n` to accept n FP16 ULP.
* Performance counters for the preload and each inference.

## Graph ABI

```c
void            main_graph_preload(void);          /* once, at boot */
fp16_storage_t *main_graph(const void *window);    /* window: [12][32] fp16 */
void           *_reserveMemory(int32_t id);        /* id 1: the 12x16 result */
```
