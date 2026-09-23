#!/usr/bin/env python3
"""Live window for radar_attention UART output.

    python3 tformer_uart_viewer.py --port /dev/ttyUSB3 --baud 921600

Start it, then reset the board: the firmware prints once per run. The feature
window fills in as [TFWIN] values arrive, then the logits and the decision
appear. It keeps listening, so the next reset draws the next run.

Serial handling and the byte-level framing follow
radar_beamforming/uart_viewer.py, which is the version proven on this bench.
"""
from __future__ import annotations

import argparse
import queue
import re
import sys
import threading

import numpy as np

HEADER = re.compile(r'\[TFORMER\] case=([0-9a-fA-F]+) weights=([0-9a-fA-F]+) '
                    r'mode=(\w+)$')
SAMPLE = re.compile(r'\[TFWIN\]\s+(\d+)\s+([0-9a-fA-F]{4})$')
LOGIT = re.compile(r'\[TFLOG\]\s+(\d+)\s+([0-9a-fA-F]{4})$')
VERDICT = re.compile(r'\[TFORMER\] (PASSED|FAILED)$')
FOREIGN = re.compile(r'\[(RADAR|BF16)\]')

FRAMES, FEATURES, TILE, CLASSES = 12, 32, 16, 4
CLASS_NAMES = ('static', 'approaching', 'receding', 'crossing')
RAMP = ['#fcfcfb', '#cde2fb', '#9ec5f4', '#6da7ec', '#3987e5', '#2a78d6',
        '#256abf', '#184f95', '#0d366b']
ACCENT, MUTED, PENDING = '#eb6834', '#9ec5f4', '#eeedea'


def ordered(bits):
    """Monotonic unsigned key for binary16, as the firmware's argmax uses."""
    bits = np.asarray(bits).astype(np.int32)
    return np.where(bits & 0x8000, 0x8000 - (bits & 0x7fff), 0x8000 + bits)


class Decoder:
    """Chunk-safe ASCII framing: a serial read can split a line anywhere."""

    def __init__(self):
        self.pending = bytearray()
        self.window = np.zeros(2 * FRAMES * TILE, dtype=np.uint16)
        self.seen = np.zeros(2 * FRAMES * TILE, dtype=bool)
        self.logits = np.zeros(CLASSES, dtype=np.uint16)
        self.logits_seen = np.zeros(CLASSES, dtype=bool)
        self.case_id = self.mode = self.verdict = None
        self.foreign = False

    def start(self, case_id, mode):
        self.window[:] = 0
        self.seen[:] = False
        self.logits[:] = 0
        self.logits_seen[:] = False
        self.case_id, self.mode, self.verdict = case_id, mode, None

    def line(self, raw):
        try:
            line = raw.decode('ascii').strip()
        except UnicodeDecodeError:
            return

        if FOREIGN.search(line):
            self.foreign = True
            return

        header = HEADER.search(line)
        if header:
            self.start(header.group(1), header.group(3))
            return
        if self.case_id is None:
            return

        sample = SAMPLE.search(line)
        if sample:
            index = int(sample.group(1))
            if 0 <= index < self.window.size:
                self.window[index] = int(sample.group(2), 16)
                self.seen[index] = True
            return

        logit = LOGIT.search(line)
        if logit:
            index = int(logit.group(1))
            if 0 <= index < CLASSES:
                self.logits[index] = int(logit.group(2), 16)
                self.logits_seen[index] = True
            return

        verdict = VERDICT.search(line)
        if verdict:
            self.verdict = verdict.group(1)

    def feed(self, chunk):
        for byte in chunk:
            if byte == 10:
                self.line(bytes(self.pending))
                self.pending.clear()
            else:
                self.pending.append(byte)
                if len(self.pending) > 1024:        # never grow without bound
                    self.pending.clear()

    def status(self):
        if self.foreign:
            return ('this board is running radar_beamforming, '
                    'not radar_attention')
        if self.case_id is None:
            return 'waiting for the firmware to print — reset the board'
        if self.verdict is None:
            return (f'receiving {self.mode}: {int(self.seen.sum())} of '
                    f'{self.window.size} samples')
        return f'case {self.case_id}  |  {self.mode}  |  {self.verdict}'


def open_serial(port, baud):
    """Open with DTR and RTS deasserted.

    pyserial raises both by default; on an FTDI-attached board that can reset
    the target or hold the line. radar_beamforming's viewer clears them first
    and works on this bench, so do the same.
    """
    import serial
    device = serial.Serial(port=None, baudrate=baud, timeout=0.1,
                           bytesize=serial.EIGHTBITS,
                           parity=serial.PARITY_NONE,
                           stopbits=serial.STOPBITS_ONE, xonxoff=False,
                           rtscts=False, dsrdtr=False, exclusive=True)
    device.dtr = False
    device.rts = False
    device.port = port
    device.open()
    return device


def reader(port, baud, chunks, stop, errors):
    try:
        with open_serial(port, baud) as link:
            print('UART open; reset the board now.', flush=True)
            while not stop.is_set():
                chunk = link.read(512)
                if chunk:
                    chunks.put(chunk)
    except Exception as exc:                                  # noqa: BLE001
        errors.append(f'{type(exc).__name__}: {exc}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', required=True, help='e.g. /dev/ttyUSB3')
    parser.add_argument('--baud', type=int, default=921600)
    args = parser.parse_args()

    import matplotlib.pyplot as plt
    from matplotlib.animation import FuncAnimation
    from matplotlib.colors import LinearSegmentedColormap

    ramp = LinearSegmentedColormap.from_list('isolde_blue', RAMP)
    ramp.set_bad(PENDING)
    figure, (left, right) = plt.subplots(
        1, 2, figsize=(10, 4.2), layout='constrained',
        gridspec_kw=dict(width_ratios=[1.5, 1.0]))
    figure.canvas.manager.set_window_title('radar_attention live')

    blank = np.ma.array(np.zeros((FRAMES, FEATURES)), mask=True)
    image = left.imshow(blank, aspect='auto', cmap=ramp, vmin=0.0, vmax=1.0,
                        interpolation='nearest',
                        extent=[0, FEATURES, FRAMES - 0.5, -0.5])
    left.axvline(TILE, color='#fcfcfb', linewidth=2.0)
    left.set_xticks([TILE / 2, TILE + TILE / 2])
    left.set_xticklabels(['bearing', 'range'])
    left.set_ylabel('frame')
    left.set_yticks(range(0, FRAMES, 2))
    left.tick_params(length=0)
    left.set_title('feature window')

    bars = right.barh(range(CLASSES), np.zeros(CLASSES), color=MUTED,
                      height=0.62)
    right.set_yticks(range(CLASSES))
    right.set_yticklabels(CLASS_NAMES)
    right.invert_yaxis()
    right.set_xlim(-1, 1)
    right.set_xlabel('logit')
    right.grid(axis='x', alpha=0.25)
    right.set_title('decision')
    title = figure.suptitle('', fontsize=11)

    decoder = Decoder()
    chunks, stop, errors = queue.Queue(), threading.Event(), []
    threading.Thread(target=reader,
                     args=(args.port, args.baud, chunks, stop, errors),
                     daemon=True).start()

    def tick(_frame):
        while True:
            try:
                decoder.feed(chunks.get_nowait())
            except queue.Empty:
                break
        values = decoder.window.view(np.float16).astype(np.float64)
        values = values.reshape(2, FRAMES, TILE).transpose(1, 0, 2)
        image.set_data(np.ma.array(
            values.reshape(FRAMES, FEATURES),
            mask=~decoder.seen.reshape(2, FRAMES, TILE).transpose(1, 0, 2)
            .reshape(FRAMES, FEATURES)))

        if decoder.logits_seen.all():
            logits = decoder.logits.view(np.float16).astype(np.float64)
            best = int(np.argmax(ordered(decoder.logits)))
            for index, bar in enumerate(bars):
                bar.set_width(logits[index])
                bar.set_color(ACCENT if index == best else MUTED)
            span = max(1e-3, float(np.abs(logits).max()))
            right.set_xlim(-1.5 * span if logits.min() < 0 else -0.05 * span,
                           1.4 * span if logits.max() > 0 else 0.05 * span)
            right.set_title(f'decision: {CLASS_NAMES[best]}')
        title.set_text(errors[-1] if errors else decoder.status())

    animation = FuncAnimation(figure, tick, interval=200, repeat=False,
                              cache_frame_data=False)
    try:
        plt.show()
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
    del animation
    if errors:
        print(errors[-1], file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
