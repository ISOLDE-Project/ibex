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

## Source revisions inspected

| Repository | Branch | Commit |
|---|---|---|
| [ISOLDE-Project/ibex](https://github.com/ISOLDE-Project/ibex/tree/tmp/cluster) | `tmp/cluster` | `bbab987` (`radar_beamforming`), `demo_3` platform |

`isolde/config/platform.yml`'s `demo_3`: three tiles, 32 KiB IRAM, **32 KiB
dataram**, 16 KiB stack. That dataram number drives most of the decisions below.

## Quick start
From the repository root:  
```bash
. ./torch.sh
make -C isolde/sw/radar_attention demo          # dataset, figures, both weight exports
make -C isolde/sw/radar_attention budget        # what each configuration puts in dataram
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

`make host-test` runs 42 tests. The ones that would catch a real bug:

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
Host, no hardware:

```bash
make demo        # dataset, figures, both weight exports
make host-test   # 42 tests
make budget      # dataram per configuration
```

On the device, from `isolde/system`. **`Makefile.radar.nodbg` cannot build this
application**: it fixes `TEST=radar_beamforming` on every line, so passing
`TEST=radar_attention` to it is silently ignored and you get the beamforming
firmware instead (`[RADAR]`/`[BF16]` markers rather than `[TFORMER]`). Use the
wrapper added here:

```bash
source ./eth.sh
cd isolde/system
make -f Makefile.tformer.nodbg test-build          # TF_MODE=encoder, default
make -f Makefile.tformer.nodbg verilate
set -o pipefail
make -f Makefile.tformer.nodbg veri-run 2>&1 | tee tformer.log
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

## Plotting what came back over UART

```bash
make plot LOG=/absolute/path/to/tformer.log
make plot LOG=.../tformer-chain.log VIEWER_FLAGS="--weights-name tformer_weights_l1.h"
make uart-plot PORT=/dev/ttyUSB3 BAUD=921600      # live, needs pyserial
```

`tformer_viewer.py` consumes the `[TFWIN]`, `[TFLOG]` and `[TFMAP]` lines the
firmware already prints; no firmware or RTL change is needed. It writes
`results/from_log/tformer_from_log.png` and a JSON summary, and prints a
per-element comparison against the golden in `inc/`.

It refuses a log that is incomplete, has a duplicate sample index, reports
FAILED, carries a repeated header, or whose `case=`/`weights=` do not match
the headers the firmware was built from. That last check matters: a stale
`inc/` and a fresh binary otherwise compare cleanly against the wrong golden.

**A log's origin cannot be inferred from its contents.** A clean parse of a
host-mock log is not an RTL result.

## What RTL actually did

Encoder mode on Verilator, `case f8df0b55c571bacd`, `weights 562527e677b64019`:

| class | golden | RTL | ULP | value |
|---|---|---|---:|---:|
| static | `ce05` | `ce05` | 0 | -24.0781 |
| approaching | `4ccd` | `4ccd` | 0 | **19.2031** |
| receding | `4a42` | `4a42` | 0 | 12.5156 |
| crossing | `c67a` | `c67b` | 1 | -6.4805 |

Three of four logits are bit-exact after **28 chained GEMMs**; the one that
differs is the smallest logit, and the decision margin is 6.69, so nothing is
close to flipping.

This is expected rather than alarming. The host mock matches
`tformer.forward_fp16` exactly because both round to FP16 after every
reduction step — but RedMulE's array need not reduce in that order.
`radar_beamforming` already allows 4 ULP against the same style of reference
for exactly this reason. What is worth noting is that the error **did not
compound** across 28 launches.

The practical consequence: the exported vectors are a tight check, not a
bit-exact one, and `MAX_TF_ULP` is load-bearing on RTL even though it is 0 on
the host. If a future change pushes this above 1, that is a regression signal,
which is why the viewer prints the per-element figure instead of a pass/fail.

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
tests/               host mock, schedule test, feature harness, budget tool
```

## Not done

- **Chained mode has not been run on RTL**, only on the host mock. Encoder
  mode has.
- The RTL logit difference is characterised (1 ULP, smallest logit) but not
  explained: RedMulE's internal reduction order has not been compared against
  the per-step-rounding model.
- **No ONNX path.** Whether the ISOLDE compiler lowers plain 12x16x16 `MatMul`
  and `Relu` has not been checked; the complex lowering hard-codes tiles 0/1
  and mask `0x3`.
- The host mock does not model RTL, DMA bank overlap, XIF, interrupts, the
  soft-float ABI or cycle timing.
- Every intermediate goes SPM -> DMEM -> SPM, because the runtime ABI has no
  SPM-to-SPM copy. On the evidence of the radar package this transfer, not the
  28 GEMMs, will dominate. Not measured.
- One dataset seed, one exported case. No regression sweep.
- The exported case is classified correctly; that is one sequence, not an
  accuracy measurement. The 0.965 figure is the host float32/FP16 number.
