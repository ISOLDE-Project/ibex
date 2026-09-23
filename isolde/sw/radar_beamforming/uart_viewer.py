#!/usr/bin/env python3
"""Render existing [RADAR]/[BF16] UART output as a live radar sweep.

Each received matrix plays through once, then the display holds its last beam.
New measurements require new firmware frames. No ONNX dependency or firmware edit.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
import queue
import re
import sys
import threading
import time

import numpy as np

HEADER = re.compile(r'\[RADAR\] case=([0-9a-fA-F]+) mode=(\w+) rows=(\d+) cols=(\d+)$')
SAMPLE = re.compile(r'\[BF16\]\s+(\d+)\s+([0-9a-fA-F]{4})\s+([0-9a-fA-F]{4})$')
ROWS, COLS = 36, 16


@dataclass
class Frame:
    case_id: str
    mode: str
    values: np.ndarray
    sequence: int


class Decoder:
    """Chunk-safe ASCII framing. Publish only complete frames ending PASSED.

    The existing format has no checksum: this checks syntax/count/finiteness,
    but cannot detect every UART bit error that becomes another valid number.
    """
    def __init__(self):
        self.pending = bytearray()
        self.discard_line = False
        self.current = None
        self.count = 0
        self.accepted = 0
        self.dropped = 0
        self.last_issue = ''

    def drop(self, reason):
        if self.current is not None:
            self.dropped += 1
            self.current = None
        self.last_issue = reason

    def line(self, raw):
        try:
            line = raw.decode('ascii').strip()
        except UnicodeDecodeError:
            self.drop('non-ASCII bytes inside a frame')
            return None
        header = HEADER.search(line)
        if header:
            if self.current is not None:
                self.drop('new header before previous frame completed')
            case, mode, rows, cols = header.groups()
            if (int(rows), int(cols)) != (ROWS, COLS):
                self.last_issue = 'unsupported shape; expected 36 x 16'
                return None
            self.current = (case, mode)
            self.bits = np.zeros((ROWS*COLS, 2), dtype=np.uint16)
            self.seen = np.zeros(ROWS*COLS, dtype=bool)
            self.count = 0
            return None
        if self.current is None:
            return None
        if '[RADAR] case=' in line:
            self.drop('malformed frame header')
        elif '[RADAR] FAILED' in line:
            self.drop('firmware reported FAILED')
        elif line.endswith('[RADAR] PASSED'):
            if self.count != ROWS*COLS:
                self.drop(f'incomplete frame: {self.count}/{ROWS*COLS} samples')
                return None
            parts = self.bits.view(np.float16).astype(np.float32)
            if not np.isfinite(parts).all():
                self.drop('NaN or infinity in received samples')
                return None
            self.accepted += 1
            frame = Frame(*self.current,
                          (parts[:, 0] + 1j*parts[:, 1]).reshape(ROWS, COLS),
                          self.accepted)
            self.current = None
            return frame
        elif '[BF16]' in line:
            match = SAMPLE.search(line)
            if not match:
                self.drop('malformed BF16 sample')
                return None
            index, real, imag = match.groups()
            index = int(index)
            if not 0 <= index < ROWS*COLS or self.seen[index]:
                self.drop('duplicate or out-of-range sample')
                return None
            self.bits[index] = int(real, 16), int(imag, 16)
            self.seen[index] = True
            self.count += 1
        return None

    def feed(self, chunk):
        frames = []
        for byte in chunk:
            if byte == 10:
                if not self.discard_line:
                    frame = self.line(bytes(self.pending))
                    if frame is not None:
                        frames.append(frame)
                self.pending.clear()
                self.discard_line = False
            elif not self.discard_line:
                self.pending.append(byte)
                if len(self.pending) > 1024:
                    self.drop('line longer than 1024 bytes')
                    self.pending.clear()
                    self.discard_line = True
        return frames

    def finish(self):
        if self.pending or self.current is not None:
            self.drop('stream ended inside a line or frame')


def open_serial(port, baud):
    import serial
    device = serial.Serial(port=None, baudrate=baud, timeout=0.1,
                           bytesize=serial.EIGHTBITS, parity=serial.PARITY_NONE,
                           stopbits=serial.STOPBITS_ONE, xonxoff=False,
                           rtscts=False, dsrdtr=False, exclusive=True)
    device.dtr = False
    device.rts = False
    device.port = port
    device.open()
    return device


class Receiver(threading.Thread):
    """Read UART independently of plotting/GIF work; retain newest 8 frames."""
    def __init__(self, args):
        super().__init__(daemon=True)
        self.args = args
        self.frames = queue.Queue(maxsize=8)
        self.stop = threading.Event()
        self.done = threading.Event()
        self.ready = threading.Event()
        self.decoder = Decoder()
        self.error = None
        self.display_skips = 0

    def run(self):
        from contextlib import ExitStack
        try:
            with ExitStack() as stack:
                source = stack.enter_context(self.args.log.open('rb') if self.args.log
                    else open_serial(self.args.port, self.args.baud))
                capture = (stack.enter_context(self.args.capture.open('wb'))
                           if self.args.capture else None)
                self.ready.set()
                print('Reading log.' if self.args.log else
                      'UART open; start/reset the FPGA application now.', flush=True)
                last_byte = time.monotonic()
                while not self.stop.is_set():
                    chunk = source.read(512)
                    if chunk:
                        last_byte = time.monotonic()
                        if capture:
                            capture.write(chunk)
                            capture.flush()
                        for frame in self.decoder.feed(chunk):
                            if self.frames.full():
                                try:
                                    self.frames.get_nowait()
                                    self.display_skips += 1
                                except queue.Empty:
                                    pass
                            self.frames.put_nowait(frame)
                            print(f'Received frame {frame.sequence}: case={frame.case_id}, '
                                  f'mode={frame.mode}, {ROWS}x{COLS}', flush=True)
                            if self.args.once:
                                return
                    elif self.args.log:
                        break
                    elif (self.args.idle_timeout and
                          time.monotonic()-last_byte > self.args.idle_timeout):
                        raise TimeoutError('UART idle timeout; check baud/port and start FPGA')
                self.decoder.finish()
        except Exception as exc:
            self.error = str(exc)
        finally:
            self.done.set()


class FramePlayback:
    """Finish one sweep before consuming the next frame; hold when idle."""
    def __init__(self, frames, plot, on_frame):
        self.frames = frames
        self.plot = plot
        self.on_frame = on_frame
        self.next_row = ROWS

    @property
    def idle(self):
        return self.next_row >= ROWS

    def tick(self):
        if self.idle:
            try:
                frame = self.frames.get_nowait()
            except queue.Empty:
                return
            self.plot.update(frame)
            self.on_frame()
            self.next_row = 0
            self.plot.note.set_text('Playing the received frame once.')
        self.plot.sweep(self.next_row)
        self.next_row += 1
        if self.idle:
            self.plot.note.set_text('Sweep complete. Holding the final beam.')


class RadarPlot:
    def __init__(self, args):
        import matplotlib.pyplot as plt
        self.args = args
        self.frame = None
        self.angles = args.angle_min + args.angle_step*np.arange(ROWS)
        self.ranges = args.range_min + args.range_step*np.arange(COLS)
        self.fig = plt.figure(figsize=(11, 6), layout='constrained')
        self.ax = self.fig.add_subplot(121, projection='polar')
        self.ax.set_theta_zero_location('N')
        self.ax.set_theta_direction(-1)
        edges = np.deg2rad(args.angle_min + args.angle_step*(np.arange(ROWS+1)-.5))
        range_edges = args.range_min + args.range_step*(np.arange(COLS+1)-.5)
        self.ax.set_thetamin(np.rad2deg(edges[0]))
        self.ax.set_thetamax(np.rad2deg(edges[-1]))
        self.ax.set_ylim(0, range_edges[-1])
        self.ax.grid(False)
        self.mesh = self.ax.pcolormesh(edges, range_edges,
                    np.full((COLS, ROWS), -45.0), cmap='magma', vmin=-45, vmax=0,
                    shading='flat')
        self.ax.set_yticks(self.ranges[[3, 7, 11, 15]])
        self.ax.grid(alpha=.25)
        self.fig.colorbar(self.mesh, ax=self.ax, label='Power / frame maximum (dB)', shrink=.65)
        self.ray, = self.ax.plot([0, 0], [0, range_edges[-1]], color='cyan', lw=1.5)
        self.profile = self.fig.add_subplot(122)
        self.curve, = self.profile.plot(self.ranges, np.full(COLS, -45.0), 'o-')
        self.profile.set(xlabel='Assigned range (m)', ylabel='Power / frame maximum (dB)',
                         ylim=(-45, 2), xlim=(range_edges[0], range_edges[-1]))
        self.profile.grid(alpha=.25)
        self.title = self.fig.suptitle('Waiting for a complete UART frame…', fontsize=13)
        self.note = self.fig.text(.5, .01, 'Each received frame plays once, then holds its final beam.',
                                  ha='center', fontsize=9, color='#526075')
        self.db = np.full((ROWS, COLS), -45.0)

    def update(self, frame):
        self.frame = frame
        power = np.abs(frame.values.astype(np.complex128))**2
        self.db = 10*np.log10(np.maximum(power/max(float(power.max()), 1e-30), 1e-5))
        self.mesh.set_array(self.db.T.ravel())

    def sweep(self, row):
        if self.frame is None:
            return
        if not 0 <= row < ROWS:
            raise ValueError('beam row must be between 0 and 35')
        theta = np.deg2rad(self.angles[row])
        self.ray.set_xdata([theta, theta])
        self.curve.set_ydata(self.db[row])
        self.profile.set_title(f'Received beam at {self.angles[row]:+.0f}°')
        self.ax.set_title('Beamformed range–angle power', pad=22)
        self.title.set_text(f'{self.args.label}  |  received frame {self.frame.sequence}  |  '
                            f'{self.frame.mode}\nSingle sweep through the received 36 × 16 matrix')

    def save_gif(self, path):
        from PIL import Image
        path.parent.mkdir(parents=True, exist_ok=True)
        frames = []
        original_dpi = self.fig.dpi
        self.fig.set_dpi(90)
        try:
            for row in range(ROWS):
                self.sweep(row)
                self.fig.canvas.draw()
                frames.append(Image.fromarray(np.asarray(self.fig.canvas.buffer_rgba()))
                              .convert('RGB'))
            # Omit the GIF loop extension: play once and hold the final image.
            # Matplotlib's PillowWriter instead writes loop=0 (infinite repeat).
            frames[0].save(path, format='GIF', save_all=True,
                           append_images=frames[1:],
                           duration=max(10, round(1000/self.args.fps)), disposal=2)
        finally:
            self.fig.set_dpi(original_dpi)
            for frame in frames:
                frame.close()
        print(f'Saved one received-frame sweep: {path}', flush=True)


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    sources = p.add_mutually_exclusive_group(required=True)
    sources.add_argument('--port', help='Linux UART, e.g. /dev/ttyUSB3')
    sources.add_argument('--log', type=Path, help='Replay a previously captured printf log')
    p.add_argument('--baud', type=int, default=115200)
    p.add_argument('--capture', type=Path, help='Save received bytes, overwriting an existing log file')
    p.add_argument('--gif', type=Path, help='Save one animated sweep of the first displayed complete frame')
    p.add_argument('--once', action='store_true', help='Receive one frame, play it once, then hold the final view')
    p.add_argument('--no-gui', action='store_true', help='Capture/export without a desktop window')
    p.add_argument('--idle-timeout', type=float, default=0, help='UART idle timeout in seconds; 0 waits indefinitely')
    p.add_argument('--fps', type=float, default=10, help='Host sweep rate; independent of acquisition rate')
    p.add_argument('--angle-min', type=float, default=-70)
    p.add_argument('--angle-step', type=float, default=4)
    p.add_argument('--range-min', type=float, default=25)
    p.add_argument('--range-step', type=float, default=25)
    p.add_argument('--label', default=None, help='Display provenance, e.g. FPGA UART or software mock')
    args = p.parse_args(argv)
    if args.baud <= 0 or args.fps <= 0 or args.idle_timeout < 0:
        p.error('baud/fps must be positive and idle-timeout nonnegative')
    if args.angle_step <= 0 or args.range_step <= 0 or args.range_min < args.range_step/2:
        p.error('invalid angle/range spacing or negative range edge')
    if args.no_gui and args.port and not args.once and not args.idle_timeout:
        p.error('--no-gui UART requires --once or --idle-timeout')
    args.label = args.label or ('Log replay' if args.log else 'FPGA UART')
    if args.capture:
        args.capture.parent.mkdir(parents=True, exist_ok=True)
    # if args.gif and args.gif.exists():
        # p.error('GIF already exists; choose a new output path')
    if args.log and args.capture:
        same_path = args.log.resolve() == args.capture.resolve()
        same_file = (args.log.exists() and args.capture.exists()
                     and args.log.samefile(args.capture))
        if same_path or same_file:
            p.error('--capture must differ from the --log input file')
    import matplotlib
    if args.no_gui:
        matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    plot = RadarPlot(args)
    receiver = Receiver(args)
    saved = False
    displayed = 0

    def on_frame():
        nonlocal saved, displayed
        displayed += 1
        if args.gif and not saved:
            plot.save_gif(args.gif)
            saved = True

    def drain():
        while True:
            try:
                frame = receiver.frames.get_nowait()
            except queue.Empty:
                break
            plot.update(frame)
            on_frame()

    def show_receiver_status():
        if receiver.error:
            plot.note.set_text('Receiver stopped: ' + receiver.error)
        elif receiver.decoder.last_issue:
            plot.note.set_text('Last rejected input: ' + receiver.decoder.last_issue)

    receiver.start()
    try:
        if args.no_gui:
            while not receiver.done.is_set() or not receiver.frames.empty():
                drain()
                receiver.done.wait(.05)
            drain()
        else:
            from matplotlib.animation import FuncAnimation
            playback = FramePlayback(receiver.frames, plot, on_frame)
            def tick(_index):
                playback.tick()
                show_receiver_status()
                if receiver.done.is_set() and receiver.frames.empty() and playback.idle:
                    animation.event_source.stop()
            animation = FuncAnimation(plot.fig, tick, interval=1000/args.fps,
                                      init_func=lambda: (), repeat=False,
                                      cache_frame_data=False)
            plt.show()
            # Keep the animation alive until the GUI exits.
            del animation
    except KeyboardInterrupt:
        pass
    finally:
        receiver.stop.set()
        receiver.join(timeout=1)
        plt.close(plot.fig)
    if receiver.error:
        print(receiver.error, file=sys.stderr)
    print(f'Complete frames={receiver.decoder.accepted}; rejected={receiver.decoder.dropped}; '
          f'display queue skips={receiver.display_skips}', flush=True)
    if not displayed:
        print('No complete frame displayed. Open the viewer before starting FPGA; keep BF_DUMP=1.',
              file=sys.stderr)
    return 0 if displayed and not receiver.error else 1


if __name__ == '__main__':
    raise SystemExit(main())