# onnx_radar_attention

`radar_attention` with the encoder compiled by onnx-mlir.  It uses the same
case and the same trained weights, and prints the same UART output, so
`tformer_uart_viewer.py`, `tformer_viewer.py` and the `make cases` images work
unchanged.  The only difference is where the encoder comes from:

| | radar_attention | onnx_radar_attention |
|---|---|---|
| encoder | `tformer_runtime3()`, hand-written | `graph.ll`: onnx-mlir `--EmitSPADELLVM` of the ONNX encoder |
| model | `tformer.py` | `tformer_onnx.py`, from the same `tformer_weights.h` |
| weights | uploaded on every inference | resident in SPM, `main_graph_preload()` once at boot |
| launches / barriers (2 layers) | 28 / 20 | 28 / 24 |

The graph covers the whole encoder: input projection + positional encoding
(fused into one K-tiled Gemm), 2 x (MultiHeadAttention on 3 tiles, FFN),
the mean pool (`ReduceMean` as one launch) and the classifier head.  It
takes the row-major `[12][32]` window; `main.c` reorders the firmware's
tile-major `[2][12][16]` window (what `[TFWIN]` prints) before the call.

## UART output

The same lines as `radar_attention` in encoder mode:

```text
[TFORMER] case=f8df0b55c571bacd weights=562527e677b64019 mode=encoder
[TFORMER] frames=12 features=32 d_model=16 d_ff=48 layers=2
[TFORMER] launches=28 barriers=24
    Terminated test  3 in ... cycles       <- main_graph_preload (extra block)
    Terminated test  2 in ... cycles       <- the encoder, as in radar_attention
[TFWIN] 0 ....   (384 lines)
[TFLOG] 0 ce05   (4 lines)
[TFORMER] class=approaching expected=approaching true=approaching
[TFORMER] errors=0 worst_ulp=0 (tolerance 4)
[TFORMER] PASSED
```

Differences:

* `launches=` / `barriers=` are the counts of `graph.ll`, not of the
  firmware schedule.
* There is one more perf-counter block, test 3, for the preload.
* Test 2 includes the window reorder and `main_graph`.  It does not include
  the weight uploads, which radar_attention's test 2 does.

On the host, the whole log equals radar_attention's for the same export
except for the `barriers=` value.  The tolerance stays `MAX_TF_ULP` = 4 as in
radar_attention, but the schedule is bit-exact with `tf_logits_golden`, so
`worst_ulp` should print 0.  Build with `-DMAX_TF_ULP=0` to require that.

Chain mode (`TF_CHAIN=1`, the beamformer in front) is not supported yet.

## Prerequisites

* The radar_attention export: `make model` in `isolde/sw/radar_attention`
  (needs torch) writes `inc/tformer_weights.h` and `inc/tformer_vectors.h`.
  `RADAR_INC=...` or `WEIGHTS_NAME=...` selects another export.
* onnx-mlir with the ISOLDE patches up to 0010.  Before 0010, ReduceMean and
  the head fall back to Krnl and the projection's rounding differs.
* The BSP runtime of the onnx_transformer series: `omrm_spm_move_f16`,
  `omrm_spm_relu_f16`, `omrm_download_tile_f16`.  `make graph` lists what
  `graph.ll` calls.
* 3 RedMulE tiles (`demo_3`).  `main.c` checks this.

## Build and run

```bash
cd isolde/system
. ./torch.sh 
 make TEST=onnx_radar_attention golden-clean golden        # models/tformer_encoder.onnx, inc/, graph.ll
 make TEST=onnx_radar_attention test-clean test-build      #generates isolde/system/sw/bin/onnx_radar_attention-*.*hex
```

`make golden` writes:

| file | contents |
|---|---|
| `models/tformer_encoder.onnx` | the encoder (`onnx_radar_model.py` via `tformer_onnx.py`) |
| `inc/tformer_config.h` | the export's `#define`s and `tf_logits_golden`, without the weight arrays |
| `inc/tformer_vectors.h` | copied: `tf_features`, `tf_class_name`, the case id |
| `inc/graph_info.h` | launches, waits and tiles of `graph.ll` |

`make golden` stops if the vectors and weights come from different exports.
`graph.ll` embeds the weights and `inc/` holds the matching case, so rebuild
both after a new `make model`.

RTL run from `isolde/system` (`. ./eth.sh` first):

```bash
make -f Makefile.nodbg veri-clean verilate                  # once
make -f Makefile.nodbg TEST=onnx_radar_attention veri-run
```

## Viewers

[radar_attention](../radar_attention)'s own scripts, run from here:

```bash
cd isolde/system
. ./torch.sh 
make TEST=onnx_radar_attention uart-plot         # live: tformer_uart_viewer.py

```

The live viewer shows `case ... | encoder | PASSED`, the feature window and
the decision.  The offline viewer also reports `launches 28 (exported 28)`
and `barriers 24 (exported 20)`.

## FPGA cases

After a ` make TEST=onnx_radar_attention test-clean test-build `, which leaves
`isolde/system/sw/bin/onnx_radar_attention.{elf,readelf}`:

```bash
cd isolde/system
. ./torch.sh 
make TEST=onnx_radar_attention cases             # isolde/system/app-images/onnx_radar_attention-<class>.ihex
```

In OpenOCD: `upload onnx_radar_attention <class>`.  `onnx_radar_case.py` is
radar_attention's `tformer_case.py`, pointed at this app's ELF.  `main.c`
declares `tf_features`, `tf_logits_golden`, `tf_true_class` and `tf_case_id`
exactly as radar_attention does.
