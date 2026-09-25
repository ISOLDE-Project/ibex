# radar_attention: classify what the beamformer sees

A 12-frame window of receive-beamformer output goes into a small transformer
encoder, and out comes one of `{static, approaching, receding, crossing}`.
The beamformer front end is [`../radar_beamforming`](../radar_beamforming); the
same three RedMulE tiles run both halves, and neither half uses scalar floating
point on Ibex.
```text
                     Input x  [B, L=12, N_FEATURES=32]
                              │
                              ▼
        ┌─────────────────────────────────────────────┐
        │  Input Projection    proj: Linear(32 → 16)  │   (no bias)
        └─────────────────────────────────────────────┘
                              │
                              ▼
                            ( + )  ◄──────── pos: Positional Embedding [12, 16]
                              │
                              ▼
                     h  [B, 12, 16]   (d_model = 16)
                              │
   ╔════════════════════════════════════════════════════════════════════╗
   ║               ENCODER LAYER  × 2   (i = 0, 1)                      ║
   ║                                                                    ║
   ║        h   ─────────────────────────────────────────┐              ║
   ║        │                                            │ (residual)   ║
   ║        ▼                                            │              ║
   ║  ┌───────────── ReLU Self-Attention  ──────────────┐│              ║
   ║  │  q = Linear(16→16)                              ││              ║
   ║  │  k = Linear(16→16)                              ││              ║
   ║  │  v = Linear(16→16)                              ││              ║
   ║  │                                                 ││              ║
   ║  │  scores = q · kᵀ / sqrt(d_model)                ││              ║
   ║  │  weights = ReLU(scores) · (exp(gate[i]) / L)    ││ ← learned    ║
   ║  │                                                 ││   gate scale ║
   ║  │  ctx = weights · v                              ││              ║
   ║  │  out = o = Linear(16→16)(ctx)                   ││              ║
   ║  └─────────────────────────────────────────────────┘│              ║
   ║        │                                            │              ║
   ║        ▼                                            │              ║
   ║      ( + )  ◄───────────────────────────────────────┘   residual   ║
   ║        │                                                           ║
   ║        h   ───────────────────────────────────────┐  (residual)    ║
   ║        │                                          │                ║
   ║        ▼                                          │                ║
   ║  ┌──────────── Feed-Forward (MLP)  ─────────────┐ │                ║
   ║  │  Linear(16 → d_ff=48)                        │ │                ║
   ║  │  ReLU                                        │ │                ║
   ║  │  Linear(48 → 16)                             │ │                ║
   ║  └──────────────────────────────────────────────┘ │                ║
   ║        │                                          │                ║
   ║        ▼                                          │                ║
   ║      ( + )  ◄─────────────────────────────────────┘  residual      ║
   ║        │                                                           ║
   ╚════════════════════════════════════════════════════════════════════╝
                              │
                              ▼
                     h  [B, 12, 16]
                              │
                              ▼
        ┌─────────────────────────────────────────────┐
        │  Mean Pool over sequence   h.mean(dim=1)    │   → [B, 16]
        └─────────────────────────────────────────────┘
                              │
                              ▼
        ┌─────────────────────────────────────────────┐
        │  Classification Head   head: Linear(16 → 4) │   (no bias)
        └─────────────────────────────────────────────┘
                              │
                              ▼
                     Logits  [B, N_CLASSES = 4]
```



`isolde/config/platform.yml`'s `demo_3`: three tiles, 32 KiB IRAM, **32 KiB
dataram**, 16 KiB stack. That dataram number drives most of the decisions below.

## Quick start
In the *isolde/system*:  
```bash
. ./torch.sh
make TEST=radar_attention demo          # dataset, figures, both weight exports
make TEST=radar_attention budget        # what each configuration puts in dataram
make TEST=radar_attention test-clean test-build
make -f Makefile.nodbg veri-clean verilate
make -f Makefile.nodbg TEST=radar_attention veri-run
```

## The model, and why these shapes

Every matrix product is one native RedMulE tile, `Z[12x16] = X[12x16] . W[16x16] (+ Y)`:

| Stage | Shape | Tiles |
|---|---|---|
| projection | `X[12x32] . We[32x16] + pos` | 2 K-tiles; the positional embedding is the Y preload |
| Q, K, V | `H . Wq`, `H . Wk`, `H . Wv` | 3 launches, **one per RedMulE**, one barrier |
| scores | `Q . K^T` | K^T zero-padded to 16x16 |
| attention | `A = ReLU(S)` | sign-bit mask on the core |
| context | `A . V` | V zero-padded to 16 rows |
| output | `H = O . Wo + H` | **residual preloaded into Y**, so it is free |
| MLP up | `H . W1` | 3 N-tiles, **one per RedMulE**, one barrier |
| | `R = ReLU(U)` | sign-bit mask |
| MLP down | `H = R . W2 + H` | 3 K-tiles accumulated in Y — see below |
| pool | `POOL . H` | constant 1/12 matrix; every output row is the mean |
| head | `pooled . Wc` | logits in row 0, columns 0..3 |

Three scalars are folded into the weights at export and cost nothing at run
time: `1/sqrt(d_model)` into `Wq`, the ReLU-attention scale `s/L` into `Wv`,
and the pooling `1/12` into `POOL`.

**Where the three tiles do not help.** MLP-down is a K-reduction into a single
accumulator, so its three launches serialise on one tile with `Y` preserved
between them — the same idiom as `beamform_runtime3`'s wave 2. That is 3 of the
8 barriers per layer. Splitting the partials across tiles would need a 3-way
sum afterwards, which is itself a K=48 GEMM, so it buys nothing.

| Model | Params | Bytes | Launches | Barriers | Test accuracy |
|---|---:|---:|---:|---:|---:|
| 2 layers, d_ff 48 | 6,272 | 12,544 | 28 | 20 | **0.965** |
| 1 layer, d_ff 48 | 3,712 | 7,424 | 16 | 12 | 0.942 |

Both were picked by validation accuracy over 5 seeds (`--seeds 5`); test is
reported, never selected on. Seed variance is real — a single seed spans
0.80 to 0.96 — so a one-seed number would have been meaningless.

## No scalar floating point, anywhere

`beamform_runtime.h` states its runtime "performs no CPU FP math". This
package holds the same line through a transformer:

| Would normally need an FPU | What happens instead |
|---|---|
| residual add | `Z = X.W + Y` with Y preloaded — the accelerator does it |
| GELU | ReLU, which on binary16 is `x & 0x8000 ? 0 : x` |
| softmax | ReLU-attention, `ReLU(QK^T) * s/L`, the constant folded into `Wv` ([Wortsman et al. 2023](https://arxiv.org/abs/2309.08586)) |
| LayerNorm | dropped; two layers do not need it here |
| `\|C\|` for the feature map | `max(\|Cr\|, \|Ci\|)`: sign mask + unsigned compare |
| log compression | 512-entry int16 Q8.8 table, 1 KiB, indexed by `bits >> 6` |
| normalisation divide | see below |

The last one is the subtle one. The feature is
`(clamp(log2 - peak, floor, 0) - floor) * 2^-11`, and the floor is **exactly
-2048 in Q8.8 log2** (-48.16 dB). Because the floor is a power of two, the
numerator is an integer in `[0, 2048]`, every such integer is exactly
representable in binary16, and the scale is an exact exponent shift. The
firmware builds the result's bit pattern with a count-leading-zeros and a
shift — no division, no rounding, and therefore **bit-exact agreement with the
Python reference** rather than agreement to some tolerance. A floor of -36 dB,
which is what this started as, would have required a real divide.

## What the host tests actually check

`make host-test` runs 44 tests. The ones that would catch a real bug:

- **The C runtime reproduces the Python FP16 reference exactly.** Not within a
  ULP tolerance — `worst_ulp=0`. The mock's GEMM and `tformer.gemm` use the
  same per-step rounding as `radar_beamforming`'s `real_accumulate`, and a test
  asserts those two agree bit for bit.
- **The schedule costs exactly what the model's shape predicts**: 28 launches,
  20 barriers, derived independently by the exporter and asserted against the
  mock's counters. A stray launch or a dropped barrier fails.
- **The mock rejects the bugs it exists to catch.** One test deliberately
  overwrites an operand with a launch in flight and asserts the mock aborts; a
  test double that never fails is worthless.
- **Two passes per run**, to catch an SPM accumulator or cursor left dirty.
- **The feature front end matches Python bit for bit** on cases the exported
  vectors do not contain: all zeros, a single peak, full dynamic range,
  saturation at the floor.
- **The generated constants cannot drift** — the log table and the angle group
  edges in the C header are compared against `radar_scene`'s own values, and
  the exported case is regenerated from the scene generator and compared.
- **The dataram assert fires** when the configuration does not fit.
- **The two generated headers cannot disagree.** `tformer_weights*.h` carries
  this model's goldens, `tformer_vectors.h` carries the data case, and both
  the firmware (at startup) and the viewer refuse to run if the two describe
  different cases. This is not hypothetical: a clean-clone `make demo` first
  exposed it, because the chain export was overwriting the encoder export's
  answers while its weights stayed put, so correct logits were compared
  against another model's golden and the firmware reported FAILED.
- **The UART parser rejects bad logs** — truncated, duplicated, wrong case or
  weights id, FAILED, repeated header — and reports a 1 ULP logit difference
  rather than absorbing it.

FP16 inference matched float32 inference exactly on all 600 test sequences,
for both models. At these magnitudes the per-step FP16 rounding changes no
decision.

## Memory: the chained mode does not fit with two layers

`make budget`:

| | encoder, 2 layers | chain, 2 layers | chain, 1 layer |
|---|---:|---:|---:|
| weights | 12,544 | 12,544 | 7,424 |
| runtime scratch | 4,864 | 4,864 | 4,864 |
| feature window | 768 | 768 | 768 |
| golden vectors | 800 | 800 | 800 |
| chain input + maps | 0 | 16,896 | 16,896 |
| **total** | **18,960** | **35,856** | **30,736** |
| headroom in 32 KiB (1 KiB reserved) | +12,784 | **-4,112** | +1,008 |

The chained input is twelve 16x16 complex snapshots plus the 36x16 steering
matrix: 16.5 KiB of `.rodata` that cannot be avoided if the firmware is to run
the beamformer itself. So `TF_CHAIN=1` ships the one-layer model, and
`main.c` carries a `_Static_assert` that fails the build rather than
overflowing quietly. The alternatives are a larger dataram or streaming the
snapshots in.

## Build and run
Host, no hardware(simulation):

In the *isolde/system*:  
### build the application
```bash
. ./torch.sh
make TEST=radar_attention golden test-clean test-build
```

### build the simulation

**Note:**  
for **this step**,
*./eth.sh* and *./torch.sh* are interchangeable

```bash
source ./eth.sh
make -f Makefile.nodbg veri-clean verilate
make -f Makefile.nodbg TEST=radar_attention veri-run
```

Chained mode, which also runs the beamformer over twelve snapshots:

```bash
make -f Makefile.tformer.nodbg TF_MODE=chain TF_DUMP_MAP=6 test-build
make -f Makefile.tformer.nodbg TF_MODE=chain veri-run 2>&1 | tee tformer-chain.log
```

`TF_DUMP_MAP=n` adds the range-angle map for frame `n` to the dump, so the
viewer can show the radar picture beside the features. It costs 1152 extra
UART lines.

Expected markers:

```text
[TFORMER] case=... weights=... mode=encoder
[TFORMER] launches=28 barriers=20
[TFORMER] class=approaching expected=approaching true=approaching
[TFORMER] errors=0 worst_ulp=1 (tolerance 4)
[TFORMER] PASSED
```

The testbench ends both success and failure with `$finish`, so do not rely on
the simulator's exit status — check the firmware markers.

## Plotting what came back over UART(FPGA)

```bash
make TEST=radar_attention uart-plot
```

## Other test cases on the FPGA (JTAG)

The firmware's built-in case is an approaching target. For the others, one
test sequence per class goes into dataram with OpenOCD's `load_image`, over
the built-in one, before the core starts. In *isolde/system*, after
`test-build`:

```bash
make TEST=radar_attention cases                      # static receding crossing
make TEST=radar_attention cases CASES="approaching"  # any subset
```

This writes `sw/bin/radar_attention-<class>.ihex`: the class's first test
sequence at the address of `tf_features[384]`, plus its FP16 reference logits
(`tf_logits_golden`), true class and case id, so `[TFORMER] PASSED` still
means the logits matched. The addresses come from `radar_attention.readelf`:
re-run `cases` after every rebuild. Then, in the OpenOCD telnet session:

```text
source jtag_upload.tcl
upload radar_attention static
```

`upload <app> <case>` is `upload <app>` with one more `load_image` /
`verify_image` before the core is started; watch it with `uart-plot`.
Encoder build only: the chained build computes its window from snapshots.

## Files

```
radar_scene.py       scenes, features, dataset, and the C feature constants
tformer.py           train, fold, FP16 reference, header export
plot_scenes.py       figures
check_learnable.py   order-blind and linear references
tformer_runtime.c    the three-tile wave schedule
tformer_features.c   beamformer output -> features, integer only
main.c               encoder mode and chained mode
tformer_viewer.py    UART/log validation and plotting
tformer_case.py      test cases as ihex files for OpenOCD load_image
tests/               host mock, schedule test, feature harness, budget tool
```


