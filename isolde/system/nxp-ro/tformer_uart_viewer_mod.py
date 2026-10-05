#!/usr/bin/env python3
"""MCD-XGRAPH execution timeline viewer for UART output.

Live, from the board:
    python3 tformer_uart_viewer_mod.py --port /dev/ttyUSB3 --baud 921600

Offline, from a gtkterm (or any terminal) capture:
    python3 tformer_uart_viewer_mod.py --file capture.log
    python3 tformer_uart_viewer_mod.py --file capture.log --save timeline.png

Start it, then reset the board: the Gantt chart builds up as MCD_XG_EVT lines
arrive.  Every other line on the UART is ignored.

Serial handling and the byte-level framing follow
radar_beamforming/uart_viewer.py, which is the version proven on this bench.

MCD-XGRAPH event format (from mcd_xgraph_rt.c):
  MCD_XG_EVTLOG_BEGIN g=<hex> count=<dec>
  MCD_XG_EVT g=<hex> n=<dec> k=<0|1|2> d=<dec> t=<dec>
  MCD_XG_EVTLOG_END   g=<hex> lost=<dec>
  k: 0=dispatch  1=complete  2=barrier

Node labels: the UART log carries only node ids, so bars are labelled n<id>
and coloured by device.  Pass --labels FILE (one "<node-id> <label>" per line,
'#' comments allowed) to name nodes, e.g. by kernel hash; bars are then
coloured by label, so the same kernel has the same colour on every device.
"""
from __future__ import annotations

import argparse
import queue
import re
import sys
import threading

# ---------------------------------------------------------------------------
# MCD-XGRAPH event regex
#
# search() rather than match(): a gtkterm capture can carry a stray CR, a
# timestamp prefix or line noise in front of the tag.  `MCD_XG_EVT\s` cannot
# match the EVTLOG_BEGIN/END lines because those continue with "LOG_".
# ---------------------------------------------------------------------------
XG_BEGIN = re.compile(r'MCD_XG_EVTLOG_BEGIN\s+g=([0-9a-fA-F]+)\s+count=(\d+)')
XG_EVT   = re.compile(r'MCD_XG_EVT\s+g=([0-9a-fA-F]+)\s+n=(\d+)\s+k=(\d+)'
                      r'\s+d=(\d+)\s+t=(\d+)')
XG_END   = re.compile(r'MCD_XG_EVTLOG_END\s+g=([0-9a-fA-F]+)\s+lost=(\d+)')

KIND_DISPATCH  = 0
KIND_COMPLETE  = 1
KIND_BARRIER   = 2

# Light fills so the black node labels stay readable inside the bars.
BAR_COLORS = [
    '#6aeadc', '#8fe36b', '#e8607a', '#f5c35b',
    '#a99cf0', '#f29bd0', '#9ec5f4', '#c9c9c9',
]
BARRIER_COLOR = '#e03030'


def load_labels(path):
    """'<node-id> <label>' per line -> {nid: label}."""
    labels = {}
    with open(path, encoding='utf-8') as fh:
        for raw in fh:
            line = raw.split('#', 1)[0].strip()
            if not line:
                continue
            nid, _, label = line.partition(' ')
            labels[int(nid, 0)] = label.strip() or nid
    return labels


# ---------------------------------------------------------------------------
# XGraphState: tracks MCD-XGRAPH events received from UART
# ---------------------------------------------------------------------------
class XGraphState:
    """Accumulates MCD_XG_EVT lines into (node, dev, t0, t1) segments and
    barrier timestamps for the Gantt chart.

    UART delivers only event lines (no static blob), so the timeline is
    reconstructed from dispatch (k=0) / complete (k=1) pairs keyed on
    (graph, node, device).  Barriers (k=2) become vertical markers.
    """

    def __init__(self):
        self._dispatch = {}    # (gid, nid, dev) -> t, waiting for complete
        self.barriers = []     # list of (gid, nid, dev, t)
        self.segments = []     # list of dict(gid, nid, dev, t0, t1)
        self.expected = None   # count= from EVTLOG_BEGIN
        self.received = 0      # MCD_XG_EVT lines since EVTLOG_BEGIN
        self.lost = 0
        self.orphans = 0       # completes with no matching dispatch
        self.ended = False     # EVTLOG_END seen
        self.dirty = False     # set when the chart needs a redraw

    def reset(self, expected=None):
        self._dispatch.clear()
        self.barriers.clear()
        self.segments.clear()
        self.expected = expected
        self.received = 0
        self.lost = 0
        self.orphans = 0
        self.ended = False
        self.dirty = True

    @property
    def open_dispatches(self):
        return len(self._dispatch)

    def add_event(self, gid, nid, kind, dev, t):
        self.received += 1
        key = (gid, nid, dev)
        if kind == KIND_DISPATCH:
            self._dispatch[key] = t
        elif kind == KIND_COMPLETE:
            t0 = self._dispatch.pop(key, None)
            if t0 is None:
                self.orphans += 1
                t0 = t
            self.segments.append(dict(gid=gid, nid=nid, dev=dev, t0=t0, t1=t))
            self.dirty = True
        elif kind == KIND_BARRIER:
            self.barriers.append((gid, nid, dev, t))
            self.dirty = True

    def end(self, lost):
        self.lost += int(lost)
        self.ended = True
        self.dirty = True

    def t_range(self):
        ts = [v for s in self.segments for v in (s['t0'], s['t1'])]
        ts += [b[3] for b in self.barriers]
        return (min(ts), max(ts)) if ts else (0, 0)

    def status(self):
        if self.expected is None and not self.received:
            return 'waiting for MCD_XG_EVT lines'
        exp = '?' if self.expected is None else self.expected
        text = f'{self.received}/{exp} events, {len(self.segments)} nodes'
        if self.ended:
            text += f', lost={self.lost}'
        if self.ended and self.expected is not None \
                and self.received != self.expected:
            text += '  [COUNT MISMATCH]'
        if self.orphans:
            text += f', {self.orphans} complete w/o dispatch'
        if self.ended and self.open_dispatches:
            text += f', {self.open_dispatches} never completed'
        return text


# ---------------------------------------------------------------------------
# Decoder: line framing + MCD-XGRAPH parsing
# ---------------------------------------------------------------------------
class Decoder:
    """Chunk-safe ASCII framing: a serial read can split a line anywhere."""

    def __init__(self):
        self.pending = bytearray()
        self.xg = XGraphState()

    def line(self, raw):
        # errors='ignore': one corrupted byte must not drop the whole line.
        line = raw.decode('ascii', errors='ignore').strip()
        if not line:
            return

        m = XG_BEGIN.search(line)
        if m:
            # New event log session -- reset graph state.
            self.xg.reset(expected=int(m.group(2)))
            return

        m = XG_EVT.search(line)
        if m:
            self.xg.add_event(m.group(1).lower(), int(m.group(2)),
                              int(m.group(3)), int(m.group(4)),
                              int(m.group(5)))
            return

        m = XG_END.search(line)
        if m:
            self.xg.end(m.group(2))

    def feed(self, chunk):
        # Split on LF; CR (gtkterm logs CRLF) is removed by strip() in line().
        for byte in chunk:
            if byte == 10:
                self.line(bytes(self.pending))
                self.pending.clear()
            else:
                self.pending.append(byte)
                if len(self.pending) > 1024:
                    self.pending.clear()

    def flush(self):
        """Parse a trailing line that has no newline (end of a capture file)."""
        if self.pending:
            self.line(bytes(self.pending))
            self.pending.clear()


# ---------------------------------------------------------------------------
# Serial reader
# ---------------------------------------------------------------------------
def open_serial(port, baud):
    """Open with DTR and RTS deasserted (avoids board resets on FTDI)."""
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


def require_pyserial():
    try:
        import serial
    except ImportError:
        raise SystemExit('pyserial is not installed in this Python '
                         f'({sys.executable}):\n  pip install pyserial==3.5')
    if not hasattr(serial, 'Serial'):
        where = (getattr(serial, '__file__', None)
                 or ', '.join(getattr(serial, '__path__', [])) or '?')
        raise SystemExit(f'the `serial` module this Python ({sys.executable}) '
                         f'imports is not pyserial:\n  {where}\n'
                         'Remove it, then install pyserial:\n'
                         '  pip uninstall -y serial\n'
                         '  pip install --force-reinstall pyserial==3.5')


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


# ---------------------------------------------------------------------------
# Gantt panel
# ---------------------------------------------------------------------------
def draw_gantt(ax, xg, labels=None):
    """Redraw the MCD-XGRAPH Gantt axes from the current XGraphState."""
    from matplotlib.lines import Line2D

    ax.cla()
    ax.set_title('MCD-XGRAPH execution timeline')
    if not xg.segments and not xg.barriers:
        ax.set_xlabel('time (cycles)')
        ax.set_yticks([])
        ax.text(0.5, 0.5, 'waiting for MCD_XG_EVT lines ...',
                ha='center', va='center', transform=ax.transAxes,
                color='#888888', fontsize=9)
        return

    devs = sorted({s['dev'] for s in xg.segments}
                  | {b[2] for b in xg.barriers})
    dev_y = {d: i for i, d in enumerate(devs)}
    t_min, t_max = xg.t_range()
    span = max(t_max - t_min, 1)

    # Colour by label when node names are known (same kernel, same colour on
    # every device), otherwise by device lane.
    label_color = {}

    def color_for(seg, label):
        if labels:
            if seg['nid'] not in labels:
                return '#e4e4e4'                  # unnamed node: neutral
            if label not in label_color:
                label_color[label] = BAR_COLORS[len(label_color)
                                                % len(BAR_COLORS)]
            return label_color[label]
        return BAR_COLORS[seg['dev'] % len(BAR_COLORS)]

    bar_h = 0.8
    min_w = span * 0.002                          # keep 0-cycle nodes visible
    for s in xg.segments:
        y = dev_y[s['dev']]
        label = (labels or {}).get(s['nid'], f"n{s['nid']}")
        x0 = s['t0'] - t_min
        w = max(s['t1'] - s['t0'], min_w)
        ax.barh(y, w, left=x0, height=bar_h, color=color_for(s, label),
                edgecolor='black', linewidth=0.8)
        ax.text(x0 + w / 2, y, label, ha='center', va='center',
                fontsize=7, color='black', clip_on=True)

    for (_g, _n, _d, t) in xg.barriers:
        ax.axvline(t - t_min, color=BARRIER_COLOR, linestyle='--',
                   linewidth=0.9, alpha=0.85)

    ax.set_yticks(range(len(devs)))
    ax.set_yticklabels([f'dev {d}' for d in devs])
    ax.set_ylim(-0.6, len(devs) - 0.4)            # dev 0 at the bottom
    ax.set_xlim(-span * 0.01, span * 1.01)
    ax.grid(axis='x', alpha=0.25, linestyle=':')
    note = f'  [lost events: {xg.lost}]' if xg.lost else ''
    ax.set_xlabel(f'Normalized time  (t_min={t_min}, range={span} cycles)'
                  f'{note}')
    if xg.barriers:
        ax.legend(handles=[Line2D([], [], color=BARRIER_COLOR, linestyle='--',
                                  linewidth=0.9, label='barrier')],
                  loc='upper left', bbox_to_anchor=(1.005, 1.0),
                  fontsize=8, frameon=True)


# ---------------------------------------------------------------------------
# Figure construction / refresh (shared by live and file modes)
# ---------------------------------------------------------------------------
def build_figure():
    import matplotlib.pyplot as plt

    figure, gantt = plt.subplots(figsize=(16, 4.2), layout='constrained')
    try:
        figure.canvas.manager.set_window_title('MCD-XGRAPH live')
    except AttributeError:                       # headless backends
        pass
    title = figure.suptitle('', fontsize=11)
    return dict(figure=figure, gantt=gantt, title=title)


def refresh(h, decoder, labels, error=None):
    """Push decoder state into the figure."""
    xg = decoder.xg
    if xg.dirty:
        xg.dirty = False
        draw_gantt(h['gantt'], xg, labels)
    h['title'].set_text(error or f'MCD-XGRAPH: {xg.status()}')


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    src = parser.add_mutually_exclusive_group(required=True)
    src.add_argument('--port', help='live UART, e.g. /dev/ttyUSB3')
    src.add_argument('--file', help='parse a saved capture (e.g. gtkterm log)')
    parser.add_argument('--baud', type=int, default=921600)
    parser.add_argument('--save', metavar='PNG',
                        help='with --file: write the figure here, no window')
    parser.add_argument('--labels', metavar='FILE',
                        help='"<node-id> <label>" per line, names the bars')
    args = parser.parse_args()
    if args.save and not args.file:
        parser.error('--save needs --file')

    labels = load_labels(args.labels) if args.labels else None

    # ---- offline: parse a capture file once and draw ----------------------
    if args.file:
        decoder = Decoder()
        with open(args.file, 'rb') as fh:
            decoder.feed(fh.read())
        decoder.flush()
        print(f'MCD-XGRAPH: {decoder.xg.status()}')

        if args.save:
            import matplotlib
            matplotlib.use('Agg')
        import matplotlib.pyplot as plt

        h = build_figure()
        decoder.xg.dirty = True
        refresh(h, decoder, labels)
        if args.save:
            h['figure'].savefig(args.save, dpi=120)
            print(f'wrote {args.save}')
        else:
            plt.show()
        return 0

    # ---- live: UART reader thread + animation ----------------------------
    require_pyserial()
    import matplotlib.pyplot as plt
    from matplotlib.animation import FuncAnimation

    h = build_figure()
    decoder = Decoder()
    decoder.xg.dirty = True                     # draw the 'waiting' placeholder
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
        refresh(h, decoder, labels, errors[-1] if errors else None)

    animation = FuncAnimation(h['figure'], tick, interval=200, repeat=False,
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