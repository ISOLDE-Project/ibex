# Live FPGA radar display over UART

The FPGA computes complex beamforming outputs. Its existing `printf` calls
send their binary16 bit patterns as ASCII UART messages. The Linux host decodes
the numbers, computes power, and draws a radar plot with an animated sweep.
It can also save a GIF. Rendering and GIF encoding run on the host.

This viewer is based on Ibex revision
`6f4781fdf479bec9f28c1328167060c3b3883b38` on `tmp/cluster`. It needs no FPGA
graphics engine, no additional RISC-V arithmetic, and no firmware edits.

## Start the display

From `isolde/sw/radar_beamforming` in your checkout:

```bash
source "$HOME/miniconda3/etc/profile.d/conda.sh"
conda activate ibex
python -m pip install -r requirements-uart.txt
python -m serial.tools.list_ports
python uart_viewer.py --port /dev/ttyUSB3 --baud 115200 \
  --capture results/uart_capture.log --gif results/uart_sweep.gif
```

Replace `/dev/ttyUSB3` with your adapter. Close minicom/screen or other readers
on that same port. The host needs serial-port access and a Matplotlib GUI
backend (e.g. Tk/Qt) for the window. Run the viewer first; when it prints
`UART open`, start/reset the FPGA application so the header is received.
The script does not issue reset commands or transmit application data.

Keep the firmware compiled with `BF_DUMP=1`. Both `runtime3` and `onnx2`
frames work. The current FPGA configuration in
`vendor/isolde-soc/rtl/io/aida_io_pkg.sv` sets 115200 baud; the UART module
defaults to 8 data bits, no parity, and one stop bit. The viewer uses the same
8-N-1 settings with flow control disabled. The usual UART wiring and your
already working FPGA programming procedure remain applicable.

Once a complete frame ending in `[RADAR] PASSED` arrives:

- The left plot displays received beam power versus angle and assigned range.
- The cyan line sweeps through the 36 look angles.
- The right plot shows the selected beam's received power versus range.
- Further complete frames replace the data and increment the received-frame
  counter. Serial reception runs separately from GUI drawing and GIF export.

`--gif` saves one 36-step sweep of the first displayed complete frame. The
GUI continues running. Existing capture/GIF files are protected against
accidental overwrite; choose a new filename for each run.

## Replay is distinct from new measurements

The current firmware computes and transmits **one** scene, then exits. The
host keeps sweeping through that same received matrix, explicitly labelled
as replay. This supplies an animated presentation of the FPGA result; it does
not imply that the FPGA is producing a new measurement at each animation step.

For moving targets/live acquisitions, firmware must repeatedly acquire or
generate new antenna samples, compute beamforming, and emit a complete header,
sample set and final status for each frame. The viewer already accepts that
stream. Repeating the existing fixed test vectors produces the same scene.
The case ID describes the vector set, not a sequence number; the host counts
received frames independently.

The earlier `beam_scan.gif` showed an analytic antenna beam pattern as steering
changed. This viewer shows the **FPGA-computed range/angle output power**. An
array pattern cannot in general be reconstructed from one C matrix alone;
that would require the steering weights/array model as additional information.

The defaults match the current example: angles -70 to +70 degrees at 4-degree
spacing, and range-bin centres 25 to 400 m at 25 m spacing. The range values
are the synthetic demo's assigned coordinates, not independently measured
distances. Geometry is not sent in the existing UART protocol; if you change
it, supply matching `--angle-min`, `--angle-step`, `--range-min`, and
`--range-step`. This version supports the current fixed 36 x 16 output shape.

## Capture/export without a desktop

Receive one result and exit after saving its GIF:

```bash
python uart_viewer.py --port /dev/ttyUSB3 --baud 115200 \
  --once --no-gui --idle-timeout 60 \
  --capture results/fpga_run_01.log --gif results/fpga_run_01.gif
```

Replay a captured UART or Verilator log later:

```bash
python uart_viewer.py --log results/fpga_run_01.log
python uart_viewer.py --log results/fpga_run_01.log --once --no-gui \
  --gif results/replay_01.gif
```

With `--fps 10`, the 36-angle host sweep lasts 3.6 seconds. This is a display
setting; it does not change UART baud rate or FPGA acquisition throughput.
With `--once` and a GUI, reception stops after one frame while its animation
continues until the window closes. Close the window or press Ctrl-C to stop.

## Existing wire format

```text
[RADAR] case=1ba8e226c32b767c mode=runtime3 rows=36 cols=16
... performance counters and diagnostic printf lines ...
[BF16] 0 3c00 bc00
[BF16] 1 ... ...
... indices 0 through 575, exactly once each ...
[RADAR] PASSED
```

Index `i` maps to beam `i // 16`, range bin `i % 16`. Each four-digit hex
field represents IEEE binary16 bits, first real then imaginary. For example,
`3c00 bc00` means `1 - j`. The viewer evaluates `power = real**2 + imag**2`
and normalizes dB to each frame's maximum. That normalization emphasizes
spatial shape; it is not an absolute calibrated power measurement across frames.

The decoder handles partial serial reads and CRLF/LF newlines. It ignores
ordinary logging, waits for a header, and discards frames with duplicate,
missing, malformed, out-of-range or non-finite samples, or firmware `FAILED`.
It resynchronizes at the next valid header. Attaching halfway through a frame
therefore requires the next run/frame. After a disconnect it reports an error;
restart the viewer to reconnect.

The current protocol has no CRC. Syntax/count checks and the firmware status
cannot detect every UART corruption that happens to produce another valid
number. For stronger integrity, a future framed binary protocol should add a
sequence number, payload length and CRC. Captured logs can also be checked
against the demo reference with the existing `beamforming.py --rtl-log` flow.

The viewer retains the latest eight complete frames if display/export falls
behind; skipped display frames are counted. `--capture` records the received
bytes independently of that display queue, using a dedicated reader thread.

## UART throughput

The existing 576 `[BF16]` lines contain exactly 11986 bytes with LF line endings
(12562 with CRLF), excluding the header, status and other printf messages.
With 8-N-1 UART, each byte needs 10 serial bits:

| Baud | LF sample dump minimum time | Theoretical maximum sample dumps/s |
|---:|---:|---:|
| 115200 | 1.040 s | 0.961 |
| 921600 | 0.130 s | 7.689 |

These are wire-time calculations, not measured FPGA performance; compute,
printing, framing and other logs add time. The 921600 row is hypothetical:
changing only the host option is insufficient. FPGA baud configuration,
clock/divider accuracy and adapter support must match and be verified.

The current UART backpressures MMIO writes when the transmitter is not ready,
so a large printf dump can stall Ibex between scans. The radar demo stops its
compute counters before validation/printing; those counters omit UART time.

For higher acquisition rates, a binary payload would need 2304 bytes for the
full complex frame, or 1152 bytes for FP16 power only, before framing/CRC.
Those are future protocol options; this patch uses the current text format.

## Validation

```bash
make uart-test
```

Tests cover chunked/CRLF input, ordinary logs, dropped/corrupt frames, new-frame
resynchronization, repeated scenes, numerical decoding and Linux pseudo-terminal
delivery through the actual pySerial reader. The supplied example GIF is made
from the earlier **host software mock** log, with that provenance in its title.
No physical FPGA/USB-UART or desktop GUI was available during preparation.

Library references:

- [pySerial API](https://pyserial.readthedocs.io/en/latest/pyserial_api.html)
- [Matplotlib PillowWriter](https://matplotlib.org/stable/api/_as_gen/matplotlib.animation.PillowWriter.html)
