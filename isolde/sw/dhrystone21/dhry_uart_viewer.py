#!/usr/bin/env python3
"""Live window for dhrystone21: AIDA's Dhrystone result next to Arm Cortex-M.

    python3 dhry_uart_viewer.py --port /dev/ttyUSB3               # ZCU104
    python3 dhry_uart_viewer.py --replay log/aida_tb/0/waves-0/dhrystone21.log
    python3 dhry_uart_viewer.py --replay uart.log --save dhrystone.png

Start it, then reset the board. The firmware prints one report per run; when
the report is complete, its DMIPS/MHz goes into the bar chart next to the
Cortex-M figures Arm publishes. The window keeps listening, so each reset
adds or updates a run. Runs are grouped by configuration (I-cache, number of
runs), so a build with -DDHRY_ICACHE=1 shows up as its own bar.

Left: DMIPS/MHz, AIDA (measured) against Arm Cortex-M (published). Hover a
bar for its source. Right: the latest run (cycles and instructions per run,
IPC, self-check, how it compares with each Cortex-M).

The Arm numbers are Dhrystone 2.1 "ground rules" figures (no inlining,
separate compilation; Arm AN273), which is how dhrystone21 is built. Arm's
inlined or multi-file numbers are much higher and are not comparable. Use
--refs to plot other reference cores from a CSV (name,dmips_per_mhz[,source]).

Serial handling is radar_attention/tformer_uart_viewer.py's (DTR/RTS cleared,
chunk-safe line framing), the version proven on this bench.
"""
from __future__ import annotations

import argparse
import csv
import queue
import re
import sys
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'radar_attention'))
import tformer_uart_viewer as tv  # noqa: E402  (reader, require_pyserial)

VAX_DPS = 1757  # Dhrystones per second of the VAX 11/780 = 1 DMIPS

# ---------------------------------------------------------------------------
# Reference cores
# ---------------------------------------------------------------------------
_ARM_TABLE_2020 = ('Arm Cortex-M Processor Comparison Table v3 (2020)',
                   'https://developer.arm.com/-/media/Arm%20Developer%20'
                   'Community/PDF/Cortex-A%20R%20M%20datasheets/'
                   'Arm%20Cortex-M%20Comparison%20Table_v3.pdf')
_ARM_TABLE_2022 = ('Arm Cortex-M Processor Comparison Table (2022)',
                   'https://documentation-service.arm.com/static/'
                   '61bb37962183326f2176f8cc')
_M85_LAUNCH = ('Arm Cortex-M85 launch: 3.13 / 4.52 / 8.76 DMIPS/MHz '
               '(ground rules / inlining / multi-file)',
               'https://www.cnx-software.com/2022/04/27/arm-cortex-m85-is-'
               'faster-than-cortex-m7-offers-higher-ml-performance-than-'
               'cortex-m55/')

# name -> (DMIPS/MHz, source). Ground-rules Dhrystone 2.1 figures.
ARM_TABLES = {
    '2020': {
        'Cortex-M0':  (0.87, _ARM_TABLE_2020),
        'Cortex-M0+': (0.95, _ARM_TABLE_2020),
        'Cortex-M1':  (0.80, _ARM_TABLE_2020),
        'Cortex-M23': (0.98, _ARM_TABLE_2020),
        'Cortex-M3':  (1.25, _ARM_TABLE_2020),
        'Cortex-M4':  (1.25, _ARM_TABLE_2020),
        # 'Cortex-M33': (1.50, _ARM_TABLE_2020),
        # 'Cortex-M35P': (1.50, _ARM_TABLE_2020),
        # 'Cortex-M55': (1.60, _ARM_TABLE_2020),
        # 'Cortex-M7':  (2.14, _ARM_TABLE_2020),
        # 'Cortex-M85': (3.13, _M85_LAUNCH),
    },
    '2022': {
        'Cortex-M0':  (0.96, _ARM_TABLE_2022),
        'Cortex-M0+': (0.99, _ARM_TABLE_2022),
        'Cortex-M1':  (0.88, _ARM_TABLE_2022),
        'Cortex-M23': (1.03, _ARM_TABLE_2022),
        'Cortex-M3':  (1.24, _ARM_TABLE_2022),
        'Cortex-M4':  (1.26, _ARM_TABLE_2022),
        # 'Cortex-M33': (1.54, _ARM_TABLE_2022),
        # 'Cortex-M35P': (1.50, _ARM_TABLE_2022),
        # 'Cortex-M55': (1.69, _ARM_TABLE_2022),
        # 'Cortex-M7':  (2.31, _ARM_TABLE_2022),
        # 'Cortex-M85': (3.13, _M85_LAUNCH),
    },
}
DEFAULT_CORES = ('Cortex-M0', 'Cortex-M0+', 'Cortex-M23', 'Cortex-M3',
                 'Cortex-M4')
# DEFAULT_CORES = ('Cortex-M0', 'Cortex-M0+', 'Cortex-M23', 'Cortex-M3',
#                  'Cortex-M4', 'Cortex-M33', 'Cortex-M55', 'Cortex-M7',
#                  'Cortex-M85')

def load_refs(table, cores, csv_path):
    """Reference bars: [(name, dmips_per_mhz, source_text)]."""
    refs = {}
    chosen = ARM_TABLES[table]
    for name in cores:
        if name not in chosen:
            raise SystemExit(f'--cores: unknown core {name!r}; known: '
                             + ', '.join(chosen))
        value, (src, url) = chosen[name]
        refs[name] = (value, f'{src}\n{url}')
    if csv_path:
        with open(csv_path, newline='') as handle:
            for row in csv.reader(handle):
                if not row or row[0].lstrip().startswith('#'):
                    continue
                if row[0].strip().lower() in ('name', 'core'):
                    continue                                  # header
                try:
                    value = float(row[1])
                except (IndexError, ValueError):
                    raise SystemExit(f'{csv_path}: bad row {row!r} '
                                     '(want name,dmips_per_mhz[,source])')
                refs[row[0].strip()] = (value, row[2].strip() if len(row) > 2
                                        else str(csv_path))
    return [(name, value, src) for name, (value, src) in refs.items()]


# ---------------------------------------------------------------------------
# Decoding the firmware's report (isolde/sw/dhrystone21/dhry_1.c)
# ---------------------------------------------------------------------------
BANNER = re.compile(r'Dhrystone Benchmark, Version 2\.1')
ICACHE = re.compile(r'Ibex I-cache:\s+(enabled|disabled)')
REGATTR = re.compile(r"Program compiled (with|without) 'register'")
WARMUP = re.compile(r'Warm-up runs \(untimed\):\s+(\d+)')
STARTS = re.compile(r'Execution starts, (\d+) runs')
ENDS = re.compile(r'Execution ends')
VALUE = re.compile(r'^(\S[^:]*:|\s+[A-Za-z_]+:)\s+(.*\S)\s*$')
SHOULD = re.compile(r'^\s+should be:\s+(.*\S)\s*$')
CYC_PERF = re.compile(r'Cycles \(perfcnt\):\s+(\d+)')
CYC_CSR = re.compile(r'Cycles \(mcycle\):\s+(\d+)')
INSTRET = re.compile(r'Instructions \(minstret\):\s+(\d+)')
RESULT = re.compile(r'DHRYSTONE_RESULT runs=(\d+) cycles=(\d+) instret=(\d+) '
                    r'dmips_per_mhz_x1000=(\d+)')
TOO_SMALL = re.compile(r'Measured time too small')
SELFCHECK = re.compile(r'Self-check: (PASS|FAIL) \((\d+) mismatches\)')
LEGACY = re.compile(r'Dhrystones per 1000 cycle')            # old dhrystone.c


@dataclass
class Run:
    icache: str | None = None
    register: bool = False
    warmup: int | None = None
    runs: int | None = None
    cycles: int | None = None
    mcycle: int | None = None
    instret: int | None = None
    verdict: str | None = None
    mismatches: int | None = None
    failed_checks: list = field(default_factory=list)
    finished: float | None = None

    @property
    def dmips_per_mhz(self):
        if not self.runs or not self.cycles:
            return None
        return self.runs * 1e6 / (VAX_DPS * self.cycles)

    @property
    def key(self):
        return (self.icache, self.runs, self.register)

    @property
    def label(self):
        parts = [f"I$ {'on' if self.icache == 'enabled' else 'off'}"]
        if self.register:
            parts.append('REG')
        return f"AIDA Ibex ({', '.join(parts)})"


class Decoder:
    """Chunk-safe ASCII framing: a serial read can split a line anywhere."""

    def __init__(self):
        self.pending = bytearray()
        self.current = None          # Run being received
        self.results = {}            # Run.key -> latest completed Run
        self.latest = None           # last completed Run
        self.completed = []          # completed Runs not yet logged
        self.last_name = None        # value line awaiting its "should be"
        self.record = ''             # "Ptr_Glob->" / "Next_Ptr_Glob->"
        self.legacy = False
        self.state = 'waiting'

    def feed(self, chunk):
        for byte in chunk:
            if byte == 10:
                self.line(bytes(self.pending))
                self.pending.clear()
            elif byte != 13:
                self.pending.append(byte)
                if len(self.pending) > 1024:        # never grow without bound
                    self.pending.clear()

    def line(self, raw):
        try:
            text = raw.decode('ascii')
        except UnicodeDecodeError:
            return
        stripped = text.strip()

        if BANNER.search(stripped):
            self.current = Run()
            self.state = 'started'
            self.last_name = None
            return
        if LEGACY.search(stripped):       # old isolde/sw/dhrystone binary
            self.legacy, self.current, self.state = True, None, 'waiting'
            return
        run = self.current
        if run is None:
            return

        for pattern, attr, conv in ((ICACHE, 'icache', str),
                                    (WARMUP, 'warmup', int),
                                    (STARTS, 'runs', int),
                                    (CYC_PERF, 'cycles', int),
                                    (CYC_CSR, 'mcycle', int),
                                    (INSTRET, 'instret', int)):
            match = pattern.search(stripped)
            if match:
                setattr(run, attr, conv(match.group(1)))
                if attr == 'runs':
                    self.state = 'measuring'
                return
        match = REGATTR.search(stripped)
        if match:
            run.register = match.group(1) == 'with'
            return
        if ENDS.search(stripped):
            self.state = 'checking'
            return
        match = RESULT.search(stripped)
        if match:
            run.runs, run.cycles, run.instret = (int(match.group(i))
                                                 for i in (1, 2, 3))
            return
        if TOO_SMALL.search(stripped):
            run.cycles = None
            return
        match = SELFCHECK.search(stripped)
        if match:
            run.verdict, run.mismatches = match.group(1), int(match.group(2))
            run.finished = time.time()
            self.latest = run
            self.completed.append(run)
            if run.dmips_per_mhz is not None:
                self.results[run.key] = run
            self.current = None
            self.state = 'done'
            return

        # "Name:   value" followed by "        should be:   expected"
        should = SHOULD.match(text.rstrip('\r'))
        if should and self.last_name:
            name, value = self.last_name
            expected = should.group(1)
            if not expected.startswith('(') and value != expected:
                run.failed_checks.append(f'{name} {value} (expected {expected})')
            self.last_name = None
            return
        if self.state == 'checking' and stripped.endswith('->'):
            self.record = stripped
            return
        value = VALUE.match(text.rstrip('\r'))
        if value and self.state == 'checking':
            name = value.group(1).strip()
            if text[:1].isspace():
                name = self.record + name
            else:
                self.record = ''
            self.last_name = (name, value.group(2))

    def status(self):
        if self.state == 'waiting':
            if self.legacy:
                return ('this is the legacy isolde/sw/dhrystone report: '
                        'flash dhrystone21 instead')
            return 'waiting for the Dhrystone banner — reset the board'
        if self.state in ('started', 'measuring'):
            runs = self.current.runs if self.current else None
            return f'measuring {runs or "?"} runs through Dhrystone…'
        if self.state == 'checking':
            return 'execution ended, receiving the self-check'
        run = self.latest
        if run is None or run.dmips_per_mhz is None:
            return 'run finished without a usable cycle count'
        return (f'{run.label}: {run.dmips_per_mhz:.3f} DMIPS/MHz  |  '
                f'self-check {run.verdict}')


# ---------------------------------------------------------------------------
# Sources: the board, or a captured log
# ---------------------------------------------------------------------------
def replay(path, lines_per_second, chunks, stop, errors):
    try:
        data = Path(path).read_bytes().splitlines(keepends=True)
        print(f'replaying {path}', flush=True)
        for line in data:
            if stop.is_set():
                return
            chunks.put(line)
            if lines_per_second > 0:
                time.sleep(1.0 / lines_per_second)
    except Exception as exc:                                  # noqa: BLE001
        errors.append(f'{type(exc).__name__}: {exc}')


# ---------------------------------------------------------------------------
# Window
# ---------------------------------------------------------------------------
SURFACE, INK, INK_MUTED, GRID = '#fcfcfb', '#1f1f1f', '#5f5e5a', '#d9d8d4'
ARM_COLOR = '#2a78d6'            # isolde blue (tformer_uart_viewer RAMP)
AIDA_COLOR = tv.ACCENT           # '#eb6834'
FAIL_COLOR = '#c0392b'


def details(run, refs, clock_mhz):
    if run is None:
        return ('No complete run yet.\n\n'
                'The report ends with "Self-check: PASS/FAIL";\n'
                'the bar appears when that line arrives.')
    lines = [run.label, '']
    if run.dmips_per_mhz is None:
        lines.append('no cycle count: "Measured time too small"')
    else:
        cpr = run.cycles / run.runs
        lines += [f'runs (timed)        {run.runs}',
                  f'warm-up runs        {run.warmup}',
                  f'cycles (perfcnt)    {run.cycles}',
                  f'cycles (mcycle)     {run.mcycle}',
                  f'instret             {run.instret}',
                  f'cycles / run        {cpr:.2f}']
        if run.instret:
            lines += [f'instructions / run  {run.instret / run.runs:.2f}',
                      f'IPC                 {run.instret / run.cycles:.3f}']
        lines.append(f'DMIPS/MHz           {run.dmips_per_mhz:.3f}')
        if clock_mhz:
            lines.append(f'DMIPS @ {clock_mhz:g} MHz      '
                         f'{run.dmips_per_mhz * clock_mhz:.1f}')
    lines += ['', f'self-check          {run.verdict} '
                  f'({run.mismatches} mismatches)']
    lines += [f'  ✗ {c}' for c in run.failed_checks[:6]]
    if run.dmips_per_mhz is not None and refs:
        lines += ['', 'AIDA / Cortex-M (same DMIPS/MHz basis)']
        for name, value, _src in sorted(refs, key=lambda r: r[1]):
            lines.append(f'  {name:<12} {run.dmips_per_mhz / value:5.2f}×')
    return '\n'.join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--port', help='e.g. /dev/ttyUSB3')
    source.add_argument('--replay', type=Path, metavar='LOG',
                        help='a captured UART / Verilator log instead')
    parser.add_argument('--baud', type=int, default=115200,
                        help='default 115200 (aida_io_pkg::UART_BAUD_RATE)')
    parser.add_argument('--speed', type=float, default=300.0,
                        help='--replay: lines per second (0 = all at once)')
    parser.add_argument('--arm-table', choices=sorted(ARM_TABLES),
                        default='2020',
                        help='which Arm comparison table to plot (default '
                             '2020, the ground-rules figures)')
    parser.add_argument('--cores', default=','.join(DEFAULT_CORES),
                        help='comma-separated Cortex-M cores to show')
    parser.add_argument('--refs', type=Path, metavar='CSV',
                        help='extra/overriding references: '
                             'name,dmips_per_mhz[,source]')
    parser.add_argument('--clock-mhz', type=float,
                        help='core clock, to also print absolute DMIPS')
    parser.add_argument('--csv', type=Path, metavar='OUT',
                        help='append every completed run to this CSV')
    parser.add_argument('--save', type=Path, metavar='PNG',
                        help='headless: read the whole source, save the '
                             'chart, exit (use with --replay)')
    args = parser.parse_args(argv)
    if args.port:
        tv.require_pyserial()
    cores = [c.strip() for c in args.cores.split(',') if c.strip()]
    refs = load_refs(args.arm_table, cores, args.refs)

    import matplotlib
    if args.save:
        matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    from matplotlib.animation import FuncAnimation
    from matplotlib.patches import Patch

    plt.rcParams.update({'axes.edgecolor': GRID, 'axes.labelcolor': INK_MUTED,
                         'xtick.color': INK_MUTED, 'ytick.color': INK,
                         'text.color': INK, 'figure.facecolor': SURFACE,
                         'axes.facecolor': SURFACE})
    figure = plt.figure(figsize=(13.0, 6.6), layout='constrained')
    grid = figure.add_gridspec(1, 2, width_ratios=[1.75, 1.0])
    chart = figure.add_subplot(grid[0, 0])
    panel = figure.add_subplot(grid[0, 1])
    if figure.canvas.manager is not None:
        figure.canvas.manager.set_window_title('dhrystone21 live')
    panel.set_axis_off()
    panel_text = panel.text(0.0, 1.0, '', va='top', ha='left', fontsize=8.5,
                            family='monospace', transform=panel.transAxes)
    title = figure.suptitle('', fontsize=11)
    sources = sorted({src.split('\n')[0] for _n, _v, src in refs})
    panel.text(0.0, 0.0, 'Reference sources (hover a bar for the link):\n'
               + '\n'.join(f'• {s}' for s in sources),
               va='bottom', ha='left', fontsize=7, color=INK_MUTED,
               wrap=True, transform=panel.transAxes)

    hover = chart.annotate('', xy=(0, 0), xytext=(12, 0),
                           textcoords='offset points', va='center',
                           fontsize=7.5, color=INK, zorder=10,
                           bbox=dict(boxstyle='round,pad=0.4', fc='white',
                                     ec=GRID, lw=0.8))
    hover.set_visible(False)
    drawn = {'bars': [], 'tips': [], 'signature': None}

    def redraw(decoder):
        """Rebuild the bars (only when the set of results changed)."""
        aida = sorted(decoder.results.values(), key=lambda r: r.label)
        signature = tuple((r.key, r.cycles, r.verdict) for r in aida)
        if signature == drawn['signature']:
            return
        drawn['signature'] = signature

        rows = [(name, value, 'arm', src) for name, value, src in refs]
        for run in aida:
            src = (f'measured on AIDA: {run.runs} runs, {run.cycles} cycles, '
                   f'self-check {run.verdict}')
            failed = run.verdict != 'PASS'
            rows.append((run.label + ('  FAIL' if failed else ''),
                         run.dmips_per_mhz, 'fail' if failed else 'aida', src))
        rows.sort(key=lambda r: r[1])

        chart.clear()
        ys = range(len(rows))
        colors = [ARM_COLOR if kind == 'arm' else
                  FAIL_COLOR if kind == 'fail' else AIDA_COLOR
                  for _n, _v, kind, _s in rows]
        bars = chart.barh(list(ys), [r[1] for r in rows], height=0.62,
                          color=colors, edgecolor=SURFACE, linewidth=2.0,
                          zorder=3)
        for bar, (_n, _v, kind, _s) in zip(bars, rows):
            if kind != 'arm':                 # secondary encoding: texture
                bar.set_hatch('///')
        top = max(r[1] for r in rows)
        for y, (name, value, kind, _s) in zip(ys, rows):
            chart.text(value + top * 0.012, y, f'{value:.2f}', va='center',
                       ha='left', fontsize=8,
                       color=INK if kind != 'arm' else INK_MUTED,
                       fontweight='bold' if kind != 'arm' else 'normal')
        chart.set_yticks(list(ys))
        chart.set_yticklabels([r[0] for r in rows])
        for tick, (_n, _v, kind, _s) in zip(chart.get_yticklabels(), rows):
            if kind != 'arm':
                tick.set_fontweight('bold')
        chart.set_xlim(0, top * 1.15)
        chart.set_ylim(-0.6, len(rows) - 0.4)
        chart.set_xlabel('DMIPS/MHz  (Dhrystone 2.1, ground rules: '
                         'no inlining, separate compilation)')
        chart.grid(axis='x', color=GRID, linewidth=0.8, zorder=0)
        chart.tick_params(axis='y', length=0)
        for side in ('top', 'right', 'left'):
            chart.spines[side].set_visible(False)
        chart.set_title(f'AIDA vs Arm Cortex-M  (Arm figures: '
                        f'{"comparison table " + args.arm_table}'
                        f'{", --refs" if args.refs else ""})', fontsize=10,
                        loc='left')
        kinds = {kind for _n, _v, kind, _s in rows}
        handles = [Patch(facecolor=ARM_COLOR, edgecolor=SURFACE,
                         label='Arm Cortex-M (published)')]
        if 'aida' in kinds:
            handles.append(Patch(facecolor=AIDA_COLOR, edgecolor=SURFACE,
                                 hatch='///', label='AIDA Ibex (measured)'))
        if 'fail' in kinds:
            handles.append(Patch(facecolor=FAIL_COLOR, edgecolor=SURFACE,
                                 hatch='///', label='AIDA, self-check FAILED'))
        chart.legend(handles=handles, loc='lower right', frameon=False,
                     fontsize=8)
        chart.add_artist(hover)
        drawn['bars'], drawn['tips'] = list(bars), [
            f'{n}: {v:.3f} DMIPS/MHz\n{s}' for n, v, _k, s in rows]

    def on_move(event):
        if event.inaxes is not chart:
            if hover.get_visible():
                hover.set_visible(False)
                figure.canvas.draw_idle()
            return
        for bar, tip in zip(drawn['bars'], drawn['tips']):
            if bar.contains(event)[0]:
                hover.xy = (bar.get_width(), bar.get_y() + bar.get_height() / 2)
                hover.set_text(tip)
                hover.set_visible(True)
                figure.canvas.draw_idle()
                return
        if hover.get_visible():
            hover.set_visible(False)
            figure.canvas.draw_idle()

    figure.canvas.mpl_connect('motion_notify_event', on_move)

    decoder = Decoder()
    chunks, stop, errors = queue.Queue(), threading.Event(), []
    if args.port:
        worker = (tv.reader, (args.port, args.baud, chunks, stop, errors))
    else:
        speed = 0.0 if args.save else args.speed
        worker = (replay, (args.replay, speed, chunks, stop, errors))
    thread = threading.Thread(target=worker[0], args=worker[1], daemon=True)
    thread.start()

    def log_csv(run):
        if not args.csv:
            return
        new = not args.csv.exists()
        with open(args.csv, 'a', newline='') as handle:
            out = csv.writer(handle)
            if new:
                out.writerow(['time', 'label', 'icache', 'runs', 'warmup',
                              'cycles', 'mcycle', 'instret', 'dmips_per_mhz',
                              'selfcheck', 'mismatches'])
            out.writerow([time.strftime('%Y-%m-%d %H:%M:%S',
                                        time.localtime(run.finished)),
                          run.label, run.icache, run.runs, run.warmup,
                          run.cycles, run.mcycle, run.instret,
                          f'{run.dmips_per_mhz:.4f}'
                          if run.dmips_per_mhz else '',
                          run.verdict, run.mismatches])

    def tick(_frame):
        while True:
            try:
                decoder.feed(chunks.get_nowait())
            except queue.Empty:
                break
        while decoder.completed:
            log_csv(decoder.completed.pop(0))
        redraw(decoder)
        panel_text.set_text(details(decoder.latest, refs, args.clock_mhz))
        title.set_text(errors[-1] if errors else decoder.status())

    tick(0)
    try:
        if args.save:
            thread.join(timeout=30)
            tick(0)
            figure.savefig(args.save, dpi=120)
            print(f'saved {args.save}: {decoder.status()}', flush=True)
        else:
            # keep a reference, or the animation is garbage-collected
            figure.dhry_animation = FuncAnimation(
                figure, tick, interval=200, repeat=False,
                cache_frame_data=False)
            plt.show()
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
    if errors:
        print(errors[-1], file=sys.stderr)
        return 1
    if args.save and decoder.latest is None:
        print('no complete Dhrystone report in the source', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
