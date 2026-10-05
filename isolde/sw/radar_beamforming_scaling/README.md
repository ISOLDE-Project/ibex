# Beamforming scaling test: 1, 2, and 3 RedMulE instances

This is a second bare-metal application, alongside `radar_beamforming`.
One firmware execution measures the **same complete 36-beam scan** using
one, two, and three RedMulE instances on the same bitstream. It reports
validated cycle samples through UART. `plot_cycles.py` reads those records
and creates a cycle bar graph.

The original application is unchanged. This application uses its scene,
FP16 reference, supported GEMM shape, BSP calls, and numerical tolerance.
It uses the direct BSP runtime; no ONNX-MLIR compilation or graph is needed.



## What is measured

| Active instances | Assignment of the three 12-beam blocks | Real GEMMs per full scan | Wait masks in order |
|---:|---|---:|---|
| 1 | Tile 0 processes blocks 0, 1, 2 sequentially | 12 | `0x1` twelve times |
| 2 | Tiles 0/1 process blocks 0/1; tile 0 then processes block 2 | 12 | `0x3` four times, then `0x1` four times |
| 3 | Tiles 0/1/2 process blocks 0/1/2 in one batch | 12 | `0x7` four times |

Every block uses four real GEMMs:

```text
Cr = Ar Br + Ai (-Bi)
Ci = Ar Bi + Ai Br
```

Each wave launches all active instances before its barrier. The two-instance
tail never waits for the idle second tile. Outputs are downloaded before
scratchpad space is reused. Transfers through the shared loader remain
serialized as in the original app, while accelerator execution can overlap.

Two instances cannot split three blocks evenly. The compute-only ideal from
these batch counts is 1.5x for two instances and 3x for three, relative to
one; transfer, dispatch, synchronization and other costs reduce those gains.
The graph reports the measured result without assuming a speedup.

Timing uses the **AIDA platform performance counter**, using measurement
ID `0xBF`. The first ID write at `MMADDR_PERF_COUNTERS` (`0x8000000C`)
starts measurement; the second stops it. The elapsed unsigned 32-bit count
is read from `MMADDR_PERF_COUNTERS + 4` (`0x80000010`). It measures one full
`beamform_scaling` call, including uploads, zeroing, dispatch, accelerator
execution, waits and downloads, plus timer/fence overhead. The initial event
clear, output poisoning, validation, and application UART printing are outside
the timed interval. There is no timer-overhead subtraction. Disable any BSP
debug logging inside the driver for comparable measurements. The result is
platform cycles, not a sum of individual accelerator counters or UART wall time.
Keep the board clock, bitstream, compiler settings and interrupt activity
consistent across comparisons. Counts represent software-selected active
tiles on a bitstream with at least three tiles, not three different bitstreams.
The exposed result is 32 bits: each individual scan must take fewer than
2^32 platform cycles. Counter wrap is not detectable from this register;
the firmware measures each scan separately instead of accumulating all
repetitions into one hardware interval.

Defaults in `bench_config.h`:

- One unmeasured, validated warm-up for each configuration.
- Five measured scans per configuration, fifteen samples total.
- Instance order rotates: 1/2/3, 2/3/1, 3/1/2, and repeats.
- All 576 complex outputs are validated after every scan. NaN/Inf and
  implausible magnitudes fail; finite values pass with <=4 ULP **or**
  absolute amplitude error <=2^-12, as in the original application.
- Output buffers are filled with NaNs before every call to expose missing
  writes instead of accidentally reusing previous valid results.
- A validation failure or zero cycle delta terminates the run with failure.

Change `BF_BENCH_REPEATS`/`BF_BENCH_WARMUPS` in the configuration header, or
pass them to the supplied build wrapper, which cleans and rebuilds. Five
samples give a quick initial comparison; increase repetitions for variability
studies. Warm-ups are not reported as measured samples.


```bash
make TEST=radar_beamforming_scaling golden test-clean test-build
```

