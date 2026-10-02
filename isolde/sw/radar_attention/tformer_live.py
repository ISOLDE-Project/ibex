#!/usr/bin/env python3
"""Live window for radar_attention UART output.

Opens immediately and fills the 12x32 feature window in as `[TFWIN]` samples
arrive, then draws the logits and the decision when the run completes.  It
keeps listening afterwards, so resetting the board starts the next frame.

    python3 tformer_live.py --port /dev/ttyUSB3 --baud 921600

This is the streaming counterpart to `tformer_viewer.py`, which validates and
plots a finished log.  The accumulation logic lives in `LiveFrame` and is
driven by an ordinary iterator of lines, so it is tested without a display.

The firmware prints once per run.  If the board has already finished, nothing
arrives until you reset it, and the window says so rather than sitting blank.
"""
from __future__ import annotations

import argparse
import os
import queue
import re
import sys
import threading
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import radar_scene as rs                                           # noqa: E402
import tformer_viewer as tv                                        # noqa: E402

# Markers from the *other* application in this repo. Seeing these means the
# board is running radar_beamforming, which is worth saying out loud rather
# than waiting for a [TFORMER] line that will never come.
FOREIGN = re.compile(r'\[(RADAR|BF16)\]')


class LiveFrame:
    """One firmware run, accumulated as its lines arrive.

    `feed` returns 'header', 'sample', 'complete', 'foreign' or None so the
    display can react without re-parsing anything.
    """

    def __init__(self, frames=rs.N_FRAMES, classes=len(rs.CLASSES)):
        self.frames, self.classes = frames, classes
        self.reset()

    def reset(self):
        self.window = np.zeros(2 * self.frames * 16, dtype=np.uint16)
        self.filled = np.zeros(2 * self.frames * 16, dtype=bool)
        self.logits = np.zeros(self.classes, dtype=np.uint16)
        self.logits_filled = np.zeros(self.classes, dtype=bool)
        self.case_id = self.weights_id = self.mode = None
        self.launches = self.barriers = None
        self.passed = None
        self.foreign = False
        self.lines = []

    @property
    def samples(self):
        return int(self.filled.sum())

    @property
    def complete(self):
        return self.passed is not None

    def feed(self, line):
        self.lines.append(line)

        if FOREIGN.search(line):
            self.foreign = True
            return 'foreign'

        header = tv.HEADER.search(line)
        if header:
            # A second header means the board restarted mid-capture.
            if self.case_id is not None:
                previous = self.lines[-1:]
                self.reset()
                self.lines = previous
            self.case_id, self.weights_id, self.mode = header.groups()
            return 'header'

        cost = tv.COST.search(line)
        if cost:
            self.launches, self.barriers = (int(cost.group(1)),
                                            int(cost.group(2)))
            return 'header'

        sample = tv.WINDOW.search(line)
        if sample:
            index = int(sample.group(1))
            if 0 <= index < self.window.size:
                self.window[index] = int(sample.group(2), 16)
                self.filled[index] = True
            return 'sample'

        logit = tv.LOGIT.search(line)
        if logit:
            index = int(logit.group(1))
            if 0 <= index < self.classes:
                self.logits[index] = int(logit.group(2), 16)
                self.logits_filled[index] = True
            return 'sample'

        if '[TFORMER] PASSED' in line:
            self.passed = True
            return 'complete'
        if '[TFORMER] FAILED' in line:
            self.passed = False
            return 'complete'
        return None

    def text(self):
        return ''.join(self.lines)

    def status(self):
        if self.foreign:
            return ('this board is running radar_beamforming, not '
                    'radar_attention')
        if self.case_id is None:
            return 'waiting for the firmware to print (reset the board)'
        if not self.complete:
            return (f'receiving {self.mode}: {self.samples} of '
                    f'{self.window.size} samples')
        return f'run complete: {"PASSED" if self.passed else "FAILED"}'


def reader(port, baud, lines, stop, on_error):
    """Serial reader thread: push decoded lines, never block the display."""
    try:
        import serial
    except ImportError:
        on_error('pyserial is not installed: pip install pyserial')
        return
    try:
        with serial.Serial(port, baud, timeout=0.2) as link:
            pending = bytearray()
            while not stop.is_set():
                chunk = link.read(4096) or b''
                pending.extend(chunk)
                while b'\n' in pending:
                    raw, _, rest = pending.partition(b'\n')
                    pending = bytearray(rest)
                    lines.put(raw.decode('ascii', errors='replace').strip())
    except Exception as exc:                                  # noqa: BLE001
        on_error(f'{type(exc).__name__}: {exc}')


def drive(frame, source, on_event=None, limit=None):
    """Feed an iterator of lines into a frame. Used by the tests and the GUI."""
    count = 0
    for line in source:
        event = frame.feed(line)
        if on_event is not None:
            on_event(event, frame)
        count += 1
        if limit is not None and count >= limit:
            break
        if event == 'complete':
            break
    return frame


def build_figure(frame, golden):
    import matplotlib.pyplot as plt
    import plot_scenes as ps

    ps.style()
    figure, axes = plt.subplots(1, 2, figsize=(9.6, 3.9),
                                gridspec_kw=dict(width_ratios=[1.4, 1.0]))
    figure.canvas.manager.set_window_title('radar_attention live')

    blank = np.full((frame.frames, 32), np.nan)
    colours = ps.SEQUENTIAL.copy()
    colours.set_bad('#eeedea')                    # not yet received
    image = axes[0].imshow(blank, aspect='auto', cmap=colours, vmin=0.0,
                           vmax=1.0, interpolation='nearest',
                           extent=[0, 32, frame.frames - 0.5, -0.5])
    axes[0].axvline(16, color=ps.SURFACE, linewidth=2.0)
    axes[0].set_xticks([8, 24])
    axes[0].set_xticklabels(['bearing', 'range'])
    axes[0].set_ylabel('frame')
    axes[0].set_yticks(range(0, frame.frames, 2))
    axes[0].tick_params(length=0)
    axes[0].set_title('feature window')

    names = list(rs.CLASSES[:golden['classes']])
    bars = axes[1].barh(range(len(names)), [0] * len(names),
                        color='#9ec5f4', height=0.62)
    axes[1].set_yticks(range(len(names)))
    axes[1].set_yticklabels(names)
    axes[1].invert_yaxis()
    axes[1].axvline(0, color=ps.GRID, linewidth=0.8)
    axes[1].grid(True, axis='x', linewidth=0.6)
    axes[1].set_axisbelow(True)
    axes[1].set_xlabel('logit')
    axes[1].set_title('decision')
    axes[1].set_xlim(-1, 1)

    status = figure.text(0.5, 0.965, '', ha='center', fontsize=9.5,
                         color=ps.INK_SECONDARY)
    figure.tight_layout(rect=(0, 0, 1, 0.92))
    return dict(figure=figure, axes=axes, image=image, bars=bars,
                status=status, palette=ps, names=names)


def refresh(view, frame, golden):
    import numpy as np

    values = frame.window.view(np.float16).astype(np.float64)
    values[~frame.filled] = np.nan
    view['image'].set_data(np.ma.masked_invalid(
        values.reshape(2, frame.frames, 16).transpose(1, 0, 2)
        .reshape(frame.frames, 32)))

    headline = frame.status()
    if frame.complete and frame.logits_filled.all():
        logits = frame.logits.view(np.float16).astype(np.float64)
        best = int(np.argmax(tv.ordered(frame.logits)))
        span = max(1e-3, float(np.abs(logits).max()))
        for index, bar in enumerate(view['bars']):
            bar.set_width(logits[index])
            bar.set_color(view['palette'].CLASS_COLOURS['approaching']
                          if index == best else '#9ec5f4')
        view['axes'][1].set_xlim(-1.55 * span if logits.min() < 0 else -0.05,
                                 1.45 * span if logits.max() > 0 else 0.05)
        view['axes'][1].set_title(f'decision: {view["names"][best]}')
        if frame.case_id == golden['case_id']:
            result = tv.compare(dict(window=frame.window, logits=frame.logits),
                                golden)
            headline += (f'   worst {max(result["worst_window_ulp"], result["worst_logit_ulp"])}'
                         f' ULP vs golden   margin {result["margin"]:.2f}')
        else:
            headline += '   (case does not match inc/, not compared)'
    view['status'].set_text(headline)
    view['figure'].canvas.draw_idle()


def run(port, baud, golden, out_dir=None, poll=0.1, max_seconds=None):
    import matplotlib.pyplot as plt

    frame = LiveFrame(frames=golden['frames'], classes=golden['classes'])
    view = build_figure(frame, golden)
    refresh(view, frame, golden)
    plt.show(block=False)

    lines, stop = queue.Queue(), threading.Event()
    errors = []
    thread = threading.Thread(target=reader,
                              args=(port, baud, lines, stop, errors.append),
                              daemon=True)
    thread.start()
    print(f'listening on {port} at {baud} baud; close the window to stop',
          file=sys.stderr, flush=True)
    print('the firmware prints once per run: reset the board to see a frame',
          file=sys.stderr, flush=True)

    started, saved = time.monotonic(), False
    try:
        while plt.fignum_exists(view['figure'].number):
            drained = False
            while True:
                try:
                    line = lines.get_nowait()
                except queue.Empty:
                    break
                event = frame.feed(line)
                drained = True
                if event == 'complete':
                    saved = False
            if errors:
                view['status'].set_text(errors[-1])
                view['figure'].canvas.draw_idle()
            if drained:
                refresh(view, frame, golden)
                if frame.complete and not saved and out_dir is not None:
                    saved = True
                    out_dir.mkdir(parents=True, exist_ok=True)
                    (out_dir / 'uart_capture.log').write_text(frame.text())
                    view['figure'].savefig(out_dir / 'tformer_live.png')
            plt.pause(poll)
            if max_seconds is not None and time.monotonic() - started > max_seconds:
                break
    finally:
        stop.set()
    return frame


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', required=True)
    parser.add_argument('--baud', type=int, default=921600)
    parser.add_argument('--inc', type=Path, default=Path('inc'))
    parser.add_argument('--weights-name', default='tformer_weights.h')
    parser.add_argument('--out-dir', type=Path,
                        default=Path('results/from_uart'))
    parser.add_argument('--poll', type=float, default=0.1)
    args = parser.parse_args()

    fallback = (f'  python3 tformer_viewer.py --port {args.port} '
                f'--baud {args.baud} --capture uart.log --inc {args.inc}')
    if not tv.has_display():
        raise SystemExit('no DISPLAY or WAYLAND_DISPLAY: a live window needs '
                         'one. Capture the run instead:\n' + fallback)
    reasons = []
    backend = tv.try_interactive_backend(reasons=reasons)
    if backend is None:
        detail = '\n'.join(f'  {name}: {why}' for name, why in reasons)
        raise SystemExit(
            'no working interactive matplotlib backend:\n' + detail
            + '\nInstall one, for example:\n'
              '  pip install pyqt5          # or\n'
              '  sudo apt install python3-tk\n'
              'Or capture the run headlessly instead:\n' + fallback)
    print(f'using the {backend} backend', file=sys.stderr)

    golden = tv.load_golden(args.inc, args.weights_name)
    frame = run(args.port, args.baud, golden, args.out_dir, args.poll)
    if frame.foreign:
        print('The board printed [RADAR]/[BF16] markers: it is running '
              'radar_beamforming, not radar_attention. Build and load this '
              'application first:\n'
              '  make -C ../../system -f Makefile.tformer.nodbg test-build',
              file=sys.stderr)
        return 2
    return 0 if frame.complete and frame.passed else 1


if __name__ == '__main__':
    raise SystemExit(main())