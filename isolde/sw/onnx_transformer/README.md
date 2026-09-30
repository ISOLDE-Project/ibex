# ONNX transformer firmware test

Validates onnx-mlir's RedMulE schedule for the ISOLDE transformer blocks
against the RTL, like `onnx_tiling_gemm` does for the tiled Gemm.  The
default block is one encoder layer of the radar_attention model:

```text
h1 = h + MultiHeadAttention(h, h)        (one head, ReLU attention)
y  = h1 + PositionwiseFeedForward(h1)    (d_ff = 48)
```

`BLOCK` selects the block (the models of onnx-mlir
`test-isolde/transformer`):

| BLOCK | graph | launches (waits) | tiles |
|---|---|---|---|
| `layer` (default) | `EncoderLayer` = mha + ffn, residuals included | 12 (10) | 3 |
| `mha` | `h + MultiHeadAttention(h, h)` | 6 (4) | 3 |
| `ffn` | `h + PositionwiseFeedForward(h)` | 6 (6) | 1 |
| `proj` | `window[12,32] . Wproj + P` | 2 (2) | 1 |
| `proj_layer` | `proj`, then `EncoderLayer` | 14 (12) | 3 |

(onnx-mlir with patches 0008-0010.  Older builds run everything on tile 0,
one wait per launch.)

What `graph.ll` does for `layer`: Q, K and V are launched on RedMulE tiles
0, 1 and 2 together and share one wait; K^T (transposed on the way) and V
move to tile 0 through data memory (`omrm_spm_move_f16`); S = Q K^T,
A = ReLU(S) (in SPM, `omrm_spm_relu_f16`), O = A V, h1 = O Wo + h (h
preloaded into Y); then the FFN tiles on tile 0.  Intermediates never leave
the SPMs; the constant weights are resident, uploaded once by
`main_graph_preload()`.  Only the final 12x16 result is downloaded.

## Prerequisites

* onnx-mlir with the ISOLDE patches, 0010 for `proj` / `proj_layer` (their
  golden assumes Add(MatMul) fused into one Gemm).  `layer`, `mha`, `ffn`
  also work with older builds.
* `isolde/system/bsp/onnx_redmule_runtime.c` with the functions `graph.ll`
  calls; `make graph` prints them, e.g.

  ```text
  graph.ll: 12 launches, 10 waits on 3 tile(s); _reserveMemory ids [1]
    runtime: omrm_download_f16, omrm_gemm_f16_16_12_16, omrm_spm_move_f16,
             omrm_spm_relu_f16, omrm_upload_tile_f16, omrm_wait, omrm_zero_f16
  ```

  Beyond `tmp/cluster`: `omrm_spm_move_f16`, `omrm_spm_relu_f16`,
  `omrm_spm_transpose_f16`, `omrm_spm_copy_f16`, `omrm_download_tile_f16`
  (commit "bsp: in-SPM transforms, cross-tile move, strided download").
* A platform with at least as many RedMulE tiles as the schedule uses
  (`jobs.yml`: `demo_3`, 3 tiles).  `main.c` checks it.
* Python: `numpy`, `onnx` (`onnxruntime` only for `--verify`).

## Build the test data and graph.ll

```bash
cd isolde/sw/onnx_transformer
make golden                          # BLOCK=layer, random weights (SEED=0)
make golden BLOCK=mha
make golden SOURCE=firmware          # layer 0 of the trained encoder
```

One `transformer_app.py` run writes the model and, from the same weights and
input, the data `main.c` needs; `make graph` adds `graph.ll` and its summary:

| file | contents |
|---|---|
| `models/transformer.onnx` | the graph; the weights are initializers |
| `inc/tf_input.h` | `tf_input[12 * IN_COLS]`, the graph input, row-major |
| `inc/tf_golden.h` | `tf_golden[192]`, bit-exact RedMulE FP16 result |
| `inc/tensor_dim.h` | `FRAMES`, `IN_COLS`, `D_MODEL`, `D_FF`, `BLOCK_NAME` |
| `inc/graph_info.h` | `GRAPH_TILES`, `GRAPH_LAUNCHES`, `GRAPH_WAITS` (from `graph.ll`) |

`transformer_app.py` builds the model with `generate_transformer.py` (a copy
of onnx-mlir's `test-isolde/transformer/models/generate_transformer.py`,
keep it in sync) and takes its `redmule_reference` as the golden: the
schedule onnx-mlir emits, in the RedMulE arithmetic of
`radar_attention/tformer.py` (FP16 rounding after each of the 16 reduction
steps, ReLU as a sign-bit mask).

* `SOURCE=random` (default): weights and input from `SEED`, `D_FF` (48).
* `SOURCE=firmware`: `tf_l0_*`, `tf_proj`, `tf_pos` of
  `radar_attention/inc_l1/tformer_weights.h` (`RADAR_INC=...` for another
  export).  The input is the firmware's value at the block's entry
  (`tf_features`, `tf_golden_proj` or `tf_golden_l0_attn_out`) and the golden
  must equal its value at the exit (`tf_golden_proj`,
  `tf_golden_l0_attn_out` or `tf_golden_l0_out`) bit for bit, else `make`
  stops.  So a pass is also bit-exact with the hand-written firmware.

The model, `inc/` and `graph.ll` are rebuilt whenever `BLOCK`, `SOURCE`,
`SEED` or `D_FF` change (`models/config.txt`).  `graph.ll` embeds the
weights, `inc/` the matching golden: keep them together.

## Host smoke test

```bash
make host-test [BLOCK=...] [SOURCE=...]
```

Compiles `main.c` with a host build of the graph and `tests/host_runtime.c`
-- a model of three tile-private SPMs (64-byte rows) and of the RedMulE
arithmetic, where a GEMM is only computed at the `omrm_wait` that covers it
(a missing wait or an operand touched in flight aborts) -- and runs it.  It
checks the ABI, the schedule and the data before an RTL run; it is not an
RTL simulation.

## RTL run on aida_tb

From `isolde/system` (`. ./eth.sh` first):

```bash
make -f Makefile.nodbg verilate                  # once
make -f Makefile.nodbg TEST=onnx_transformer test-clean test-build veri-run
```

or `make sim` from this directory for the second line.  `test-build`
compiles every `*.c` / `*.ll` at the top of this directory (`main.c`,
`graph.ll`; not `tests/`, not `build-host/`) with `inc/` on the include path
and links the BSP runtime.  Success ends with:

```text
[ONNX-TFMR] errors=0 worst_ulp=0 allowed_ulp=0
[ONNX-TFMR] PASSED
```

## If it fails

* Bisect by block: `ffn` (one tile, relu in SPM), `mha` (three tiles,
  moves), `proj` (plain K-tiled Gemm, as `onnx_tiling_gemm`), then `layer`.
* `make sim TEST_CPPFLAGS=-DOMRM_SPM_VIA_DMEM` (or the same variable on the
  `test-clean test-build veri-run` line; the BSP is rebuilt with it) builds `omrm_spm_relu/transpose/copy_f16` from
  download + upload through data memory, i.e. only from loader paths that
  already passed on RTL, instead of the narrow-window code.  If that passes,
  the narrow-window transforms are the problem.
* `TEST_CPPFLAGS=-DTF_ALLOWED_ULP=n` accepts n FP16 ULP (the check stays
  bit-exact by default).
* `_Exit` codes: `0x0bad1000` unexpected `_reserveMemory` id (main.c),
  `0x0bad0012`-`0x0bad0015` runtime argument checks.

## What main.c checks

* The platform has at least `GRAPH_TILES` RedMulE tiles.
* `main_graph_preload()` once, then `main_graph(tf_input)` twice; the
  second run fails if the first overwrote resident weights.
* The result buffer is filled with NaN before each run and must be the one
  `_reserveMemory(1)` handed out.
* Every value must equal `tf_golden` bit for bit (`worst_ulp == 0`).
* Performance counters for the preload and each inference.

## Graph ABI

```c
void            main_graph_preload(void);          /* once, at boot */
fp16_storage_t *main_graph(const void *h);         /* h: [12][IN_COLS] fp16 */
void           *_reserveMemory(int32_t id);        /* id 1: the 12x16 result */
```
# Results
## 1 tile
```text
[ONNX-TFMR] graph.ll bare-metal test, block layer
[ONNX-TFMR] in[12,16] -> y[12,16], d_ff=48, FP16
[ONNX-TFMR] schedule: 12 launches, 12 waits, 1 tile(s)
[ONNX-TFMR] platform: 3 RedMulE tile(s)
[ONNX-TFMR] preload:
***
    Terminated test  1 in 3346 cycles
      reads  [imemory] = 3033 
      writes [dmemory] = 0 
      reads  [dmemory] = 0 
      writes [stack] = 183 
      reads  [stack] = 183 
     ***
[ONNX-TFMR] inference 0:
***
    Terminated test  2 in 11546 cycles
      reads  [imemory] = 8046 
      writes [dmemory] = 0 
      reads  [dmemory] = 0 
      writes [stack] = 248 
      reads  [stack] = 346 
     ***
[ONNX-TFMR] run 0 worst_ulp=1
[ONNX-TFMR] inference 1:
***
    Terminated test  2 in 11547 cycles
      reads  [imemory] = 8046 
      writes [dmemory] = 0 
      reads  [dmemory] = 0 
      writes [stack] = 248 
      reads  [stack] = 346 
     ***
[ONNX-TFMR] run 1 worst_ulp=1

## 3 tiles
[ONNX-TFMR] graph.ll bare-metal test, block layer
[ONNX-TFMR] in[12,16] -> y[12,16], d_ff=48, FP16
[ONNX-TFMR] schedule: 12 launches, 10 waits, 3 tile(s)
[ONNX-TFMR] platform: 3 RedMulE tile(s)
[ONNX-TFMR] preload:
***
    Terminated test  1 in 3345 cycles
      reads  [imemory] = 3032 
      writes [dmemory] = 0 
      reads  [dmemory] = 0 
      writes [stack] = 183 
      reads  [stack] = 183 
     ***
[ONNX-TFMR] inference 0:
***
    Terminated test  2 in 14419 cycles
      reads  [imemory] = 11525 
      writes [dmemory] = 484 
      reads  [dmemory] = 384 
      writes [stack] = 129 
      reads  [stack] = 129 
     ***
[ONNX-TFMR] run 0 worst_ulp=1
[ONNX-TFMR] inference 1:
***
    Terminated test  2 in 14419 cycles
      reads  [imemory] = 11525 
      writes [dmemory] = 484 
      reads  [dmemory] = 384 
      writes [stack] = 129 
      reads  [stack] = 129 
     ***
[ONNX-TFMR] run 1 worst_ulp=1
