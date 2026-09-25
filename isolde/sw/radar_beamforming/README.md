# Radar receive beamforming on ISOLDE / Ibex

```text
SCENE GEN → SPLIT-COMPLEX → [CORE FP16 COMPLEX GEMM] → ┬─ EXPORT (header/ONNX/NPZ)
 A[36×16]     ar,ai,br,bi      Cr = ar·br − ai·bi        ├─ VALIDATION (log parse + ULP compare)
 B[16×16]                      Ci = ar·bi + ai·br        └─ VISUALIZATION (radar plots / GIF)
                              C[36×16], BLOCK_M=12                    │
                                                                  REPORT (summary.json)
```

For an animated Linux display of FPGA results received over UART, see
[UART_VIEWER.md](UART_VIEWER.md). The viewer consumes the existing `BF_DUMP=1`
printf output and can export a GIF without firmware or RTL changes.

This example forms 36 receive beams from a synthetic 16-antenna,
16-range-bin input using complex GEMM. It provides a Python radar view,
an animated receive beam pattern, a three-RedMulE bare-metal application,
and an ONNX version for the existing ISOLDE compiler flow.

The configuration [isolde/config/jobs.yml](../../config/jobs.yml) selects `demo_3`: three tiles,
32 KiB instruction RAM, 32 KiB data RAM, and a 16 KiB stack. The simulation
top is `vendor/isolde-soc/fpga/tb/aida_tb.sv` with `REDMULE_CLUSTER` enabled.

## Python first

From the repository root:

```bash
. ./torch.sh
make -C isolde/sw/radar_beamforming demo
```

```bash
python isolde/sw/radar_beamforming/beamforming.py --out-dir radar_results
```
In folder `isolde/sw/radar_beamforming`:  
`make demo` creates:

- `results/beamforming.png`: radar view, recovered directions, beam patterns,
  and error against float64.
- `results/beam_scan.gif`: analytic receive beam pattern scanning the 36 angles.
- `results/beamforming_vectors.npz` and `results/summary.json`.
- `inc/radar_vectors.h`: aligned binary16 bit patterns for bare-metal firmware.
- `model/radar_block_f16.onnx`: `com.isolde::RedMulEComplexGemm` for ISOLDE.
- `model/radar_block_portable_f32.onnx`: four ordinary MatMul operations and
  Add/Sub for a portable numerical cross-check. It is not the RedMulE graph.


## Signal model and matrix layout

This is conventional narrowband, far-field, delay-and-sum **receive**
beamforming. The array has 16 elements with spacing `d = wavelength / 2`.
Angles are measured from broadside, over the front sector only. The input
represents one snapshot **after range processing**. The range profile is
synthetic: there is no transmitted waveform, ADC sampling, range FFT, Doppler
processing, calibration, or CFAR detector in this example. The metre scale is
assigned to bins at 25 m spacing; it is not a simulated range estimate.

For antenna index `n` and look angle `theta`:

```text
a(theta)[n] = exp(+j*pi*n*sin(theta))
A[beam,n]  = conj(a(theta_beam)[n]) / 16
B[n,bin]   = synthetic complex receive sample
C[beam,bin] = sum_n A[beam,n] * B[n,bin]
P[beam,bin] = abs(C[beam,bin])**2
```

The conjugation is already included in A; the runtime does plain GEMM.
Python computes power and plots after the complex output is available.

| Tensor | Logical shape | Meaning |
|---|---|---|
| `Ar`, `Ai` | 36 x 16 | Split real/imaginary conjugate steering weights |
| `Br`, `Bi` | 16 x 16 | Split antenna samples, antenna-major |
| `Cr`, `Ci` | 36 x 16 | Split beam outputs, beam-major |
| One accelerator call | 12 x 16 times 16 x 16 | 12 angles and all 16 bins |

All buffers are contiguous row-major arrays. Real and imaginary components
occupy separate arrays; they are not interleaved. The C code stores FP16 as
`uint16_t` bits and does no scalar floating point arithmetic on Ibex.

The default scene has independent range-localized echoes and complex noise:

| Target | Angle | Zero-based range bin | Assigned range | Amplitude |
|---|---:|---:|---:|---:|
| 1 | -30 degrees | 4 | 125 m | 1.00 |
| 2 | +6 degrees | 8 | 225 m | 0.80 |
| 3 | +38 degrees | 12 | 325 m | 0.65 |

The Python FP16 model recovers all three exact scan angles. For seed 7,
maximum complex error against unquantized float64 is `5.446386e-4`, and RMS
complex error is `6.444549e-5`. These are numerical reference results.

## Mapping to the current RTL API

The current runtime exports only `omrm_gemm_f16_16_12_16(...)`. Its suffix
is in instruction order **K, M, N**: the logical operation is
`A[M,N] @ B[N,K]`, with `M=12, N=16, K=16`. The ONNX-MLIR LLVM lowering
also explicitly rejects other sizes. The 36-angle scan is therefore tiled
in software, without extending the BSP or changing RTL.

`beamform_runtime.c` assigns a distinct block to each physical tile:

| Tile | Beam rows | Scan angles |
|---|---|---|
| 0 | 0..11 | -70..-26 degrees |
| 1 | 12..23 | -22..+22 degrees |
| 2 | 24..35 | +26..+70 degrees |

Each tile uses the standard four-real-GEMM decomposition:

```text
Cr = Ar Br - Ai Bi
Ci = Ar Bi + Ai Br
```

| Wave | Work on each of tiles 0, 1, 2 | Accumulator action |
|---|---|---|
| 1 | Ar_block @ Br | Zero Y, then compute |
| 2 | Ai_block @ (-Bi) | Preserve Y; download it as Cr after the barrier |
| 3 | Ar_block @ Bi | Zero Y, then compute |
| 4 | Ai_block @ Br | Preserve Y; download it as Ci after the barrier |

Each wave launches all three tiles, then calls `omrm_wait(0x7)`. Launches
are asynchronous, but operand transfers through the shared loader are
serialized. Calls can overlap computation across tiles; simultaneous launch
and an end-to-end speedup are not assumed. There are 12 real GEMM launches
and four tile barriers per scan. This is block distribution across three
tiles, not the three-product Gauss identity.

| API call | Connection to hardware |
|---|---|
| `omrm_addr_start(tile, 0)` | Selects the tile and obtains the first SPM row |
| `omrm_upload_f16` | Transfers aligned DMEM data via the SPM loader; returns the next SPM cursor |
| `omrm_zero_f16` | Clears the tile's Y region |
| `omrm_gemm_f16_16_12_16` | Clears that tile's completion bit and issues `redmule.gemm` through XIF |
| `omrm_wait(mask)` | Waits for and clears the requested tile event bits |
| `omrm_download_f16` | Copies completed Y back to DMEM through the loader |

The runtime and RTL handle tile selection, bank layout, the loader and event
barrier. In particular, the application never changes TILESEL during an
in-flight loader transfer: the public upload/download calls block until that
transfer completes. GEMM completion is handled separately by `omrm_wait`.

The 16 FP16 values in a logical row occupy 32 payload bytes but advance the
narrow SPM cursor by **64 bytes**. Thus the per-tile layout, relative to X,
is:

| Region | FP16 elements | Payload bytes | Cursor offset | Cursor span |
|---|---:|---:|---:|---:|
| X | 192 | 384 | 0 | 768 |
| W | 256 | 512 | 768 | 1024 |
| Y | 192 | 384 | 1792 | 768 |

The total cursor span is 2560 bytes per tile. Code uses the returned upload
cursors rather than hard-coding those offsets. The loader owns the ninth-bank
overlap handling. No padding or overlapping bank words are emitted in the
Python host arrays.

Input, golden, and result arrays consume 7936 data bytes. The ONNX path adds
768 bytes of graph result buffers, before BSP/graph overhead. Check the actual
ELF map after linking; a successful hardware link has not been verified here.

## Build and run the three-tile firmware

From the repository root:

```bash
source ./eth.sh
cd isolde/system
make -f Makefile.radar.nodbg check-generated
make -f Makefile.radar.nodbg test-build
make -f Makefile.radar.nodbg verilate
set -o pipefail
make -f Makefile.radar.nodbg veri-run 2>&1 | tee radar-runtime3.log
```

The wrapper supplies `DBG_MODULE=0`, `ENABLE_SPM=1`, `VLT_TOP_MODULE=aida_tb`,
`BENDER_EXTRA_TARGET="-t fpga_sim -D REDMULE_CLUSTER"`, and
`TEST=radar_beamforming`. It explicitly selects the correct source list and
cleans firmware before each build, avoiding stale objects when changing
backends. Run build and simulation targets as separate commands.

If the current three-tile `aida_tb` simulator is already built for this same
revision/configuration, the `verilate` step can be omitted. If generated
platform files differ, review your configuration and run `make generate`
before rebuilding software and the simulator.

The firmware validates all 1152 real/imaginary scalar outputs and prints a
lossless dump of 576 complex values. It checks finite, plausible output values
and accepts either at most 4 FP16 ULP or at most `2^-12` absolute amplitude
error, accommodating values near cancellation. The numerical reference uses
the same reduction order as `isolde/sw/scripts/complex_gemm/complex_gemm.py`.

Expected markers, to be obtained by your actual simulation:

```text
[RADAR] case=1ba8e226c32b767c mode=runtime3 rows=36 cols=16
[RADAR] errors=0 ...
[BF16] 0 <real-half-bits> <imag-half-bits>
...
[RADAR] PASSED
[FPGA SIM] ... Success!
```

The current testbench ends both success and failure with `$finish`, so do not
rely only on the simulator process exit status. Check the firmware result and
plot/validate the log:

```bash
cd ../sw/radar_beamforming
make plot LOG="$(pwd)/../../system/radar-runtime3.log"
```

The parser rejects missing samples, duplicates, mismatched case IDs, firmware
failure, NaN/Inf, or numerical differences beyond tolerance. It writes
`results/from_log/beamforming_from_log.png`. A log's origin cannot be inferred
from its samples: a successful host-mock parse is not an RTL result.

With `BF_DUMP=0`, rebuilding disables the raw output dump for shorter logs.
Performance counters cover transfer/dispatch/GEMM/download (and output copies
in ONNX mode); validation and printing happen after counters stop. Measure
both modes locally before drawing performance conclusions.

## ONNX-MLIR path: existing two-tile lowering

At the inspected compiler revision, the complex operation's lowering hard-codes
tile 0 for Cr, tile 1 for Ci, and wait mask `0x3`. Merely having three tiles in
RTL does not make that lowering use tile 2.

The included ONNX model processes one 12-angle block. The firmware invokes the
generated `main_graph` three times on consecutive rows of Ar/Ai, preserving
all outputs. Each call uses two waves of two GEMMs. The full scan therefore
has 12 real GEMMs and six two-tile barriers, with tile 2 idle.

```bash
# From the repository root, with your ISOLDE environment active:
make -C isolde/sw/radar_beamforming graph \
  ONNX_MLIR=/absolute/path/to/onnx-mlir

cd isolde/system
make -f Makefile.radar.nodbg BF_BACKEND=onnx test-build
set -o pipefail
make -f Makefile.radar.nodbg BF_BACKEND=onnx veri-run 2>&1 | tee radar-onnx.log
cd ../sw/radar_beamforming
make plot LOG="$(pwd)/../../system/radar-onnx.log"
```

`graph.ll` is compiled by the existing RISC-V Clang/BSP build. The app expects
the current bare-pointer ABI returning `{Cr_pointer, Ci_pointer}`, with
`_reserveMemory(1)` and `_reserveMemory(2)` for the two output allocations,
as in `onnx_complex_gemm`. Check emitted IR if the compiler changes. This
package does not contain a fabricated `graph.ll` or claim successful custom
compiler execution.

For automatic three-tile scheduling through ONNX, a future compiler change
would need to generalize the schedule in
`src/Conversion/AISLEToAISMEM/Math/ComplexGEMM.cpp`; the direct runtime
implementation here is a concrete schedule to use as a reference. No compiler
modifications are required for either path supplied here.

## Tests and limits

`make host-test` checks:

1. Complex decomposition and physical direction/sign convention.
2. Exact agreement with the repository's FP16 reference, when run in Ibex.
3. Structural validity of both ONNX files and numerical execution of the
   portable graph for all three blocks.
4. Rejection of incomplete, duplicated, mismatched and non-finite log data.
5. The actual C scheduler and firmware using a strict host runtime mock. The
   mock delays GEMMs until waits, rejects overwrite/read before completion,
   checks the row cursor layout and tile mask, and runs the scheduler twice
   to detect stale accumulators. This does not simulate RTL, DMA bank overlap,
   XIF, interrupts, soft-float ABI or cycle timing.

The host compiler needs `_Float16`; recent GCC and Clang support it. ONNX's
generic checker only validates structure for the custom operator; its
semantics belong to the ISOLDE compiler. Real RTL execution is the remaining
integration gate, including actual numerical tolerance and memory placement.

For larger arrays or scans, preserve 12x16x16 hardware blocks and extend the
outer software tiling. More antennas require reduction tiling and careful
accumulator ordering. Dimensions in this milestone are intentionally fixed
to the currently supported runtime ABI.
