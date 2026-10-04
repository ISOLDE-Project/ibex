#!/usr/bin/env python3
"""Shared live window for the AIDA benchmark viewers.

Used by dhrystone21/dhry_uart_viewer.py and coremark/coremark_uart_viewer.py.
Each of those supplies a Bench: how to decode its firmware report, which
reference cores to compare with, and what to show for a run. This module
owns the parts they share:

  - the sources: the board's UART (radar_attention/tformer_uart_viewer.py's
    reader, DTR/RTS cleared) or a captured / Verilator log (--replay);
  - the window: a horizontal bar chart of the score, AIDA (orange, hatched;
    red and labelled FAIL if its self-check failed) against the reference
    cores (blue), a details panel for the latest run, hover tooltips with
    each bar's source;
  - --csv logging, --refs CSV references, headless --save PNG.

A decoder object must provide feed(bytes), status(), and the attributes
results (key -> latest completed run), latest (last completed run) and
completed (runs not yet logged). A run must provide score, label, key,
verdict ('PASS' / anything else), note (bar tooltip), finished (time) and
csv_row() matching Bench.csv_header.
"""
from __future__ import annotations

import argparse
import csv
import queue
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'radar_attention'))
import tformer_uart_viewer as tv  # noqa: E402  (reader, require_pyserial)

# The firmware's UART divisor is computed for aida_io_pkg::UART_CLOCK_FREQ
# (10 MHz) and 115200 baud, but the ZCU104 core runs at 80 MHz
# (xilinx_clk_mngr: 300 MHz * 4 / 15), so the line actually runs about 8x
# faster: 921600, the rate radar_attention's viewers use on this bench.
DEFAULT_BAUD = 921600

SURFACE, INK, INK_MUTED, GRID = '#fcfcfb', '#1f1f1f', '#5f5e5a', '#d9d8d4'
REF_COLOR = '#2a78d6'            # isolde blue (tformer_uart_viewer RAMP)
AIDA_COLOR = tv.ACCENT           # '#eb6834'
FAIL_COLOR = '#c0392b'


@dataclass
class Bench:
    name: str                    # window title, e.g. 'dhrystone21'
    report: str                  # e.g. 'Dhrystone report' (messages)
    metric: str                  # e.g. 'DMIPS/MHz'
    axis_label: str              # x-axis label
    ref_tables: dict             # table -> {core: (value, (source, url))}
    default_table: str
    default_cores: tuple
    ref_family: str              # e.g. 'Arm Cortex-M'
    make_decoder: Callable[[], object]
    details: Callable            # (run, refs, clock_mhz) -> str
    csv_header: list
    description: str = ''


def load_refs(bench, table, cores, csv_path):
    """Reference bars: [(name, value, source_text)]."""
    refs = {}
    chosen = bench.ref_tables[table]
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
                                     '(want name,value[,source])')
                refs[row[0].strip()] = (value, row[2].strip() if len(row) > 2
                                        else str(csv_path))
    return [(name, value, src) for name, (value, src) in refs.items()]


def ratios(score, refs, metric, family):
    """Details-panel lines: AIDA / each reference core."""
    lines = ['', f'AIDA / {family} (same {metric} basis)']
    for name, value, _src in sorted(refs, key=lambda r: r[1]):
        lines.append(f'  {name:<12} {score / value:5.2f}×')
    return lines


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


def main(bench, argv=None):
    parser = argparse.ArgumentParser(
        description=bench.description,
        formatter_class=argparse.RawTextHelpFormatter)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--port', help='e.g. /dev/ttyUSB3')
    source.add_argument('--replay', type=Path, metavar='LOG',
                        help='a captured UART / Verilator log instead')
    parser.add_argument('--baud', type=int, default=DEFAULT_BAUD,
                        help=f'default {DEFAULT_BAUD} (ZCU104: 80 MHz core, '
                             'divisor set for 115200 at 10 MHz)')
    parser.add_argument('--speed', type=float, default=300.0,
                        help='--replay: lines per second (0 = all at once)')
    parser.add_argument('--arm-table', choices=sorted(bench.ref_tables),
                        default=bench.default_table,
                        help='which reference table to plot (default '
                             f'{bench.default_table})')
    parser.add_argument('--cores', default=','.join(bench.default_cores),
                        help='comma-separated reference cores to show')
    parser.add_argument('--refs', type=Path, metavar='CSV',
                        help='extra/overriding references: '
                             'name,value[,source]')
    parser.add_argument('--clock-mhz', type=float,
                        help='core clock, to also print absolute numbers')
    parser.add_argument('--csv', type=Path, metavar='OUT',
                        help='append every completed run to this CSV')
    parser.add_argument('--save', type=Path, metavar='PNG',
                        help='headless: read the whole source, save the '
                             'chart, exit (use with --replay)')
    parser.add_argument('--save-timeout', type=float, default=30.0,
                        help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    if args.port:
        tv.require_pyserial()
    cores = [c.strip() for c in args.cores.split(',') if c.strip()]
    refs = load_refs(bench, args.arm_table, cores, args.refs)

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
        figure.canvas.manager.set_window_title(f'{bench.name} live')
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
        signature = tuple((r.key, r.score, r.verdict) for r in aida)
        if signature == drawn['signature']:
            return
        drawn['signature'] = signature

        rows = [(name, value, 'ref', src) for name, value, src in refs]
        for run in aida:
            failed = run.verdict != 'PASS'
            rows.append((run.label + ('  FAIL' if failed else ''),
                         run.score, 'fail' if failed else 'aida', run.note))
        rows.sort(key=lambda r: r[1])

        chart.clear()
        ys = list(range(len(rows)))
        colors = [REF_COLOR if kind == 'ref' else
                  FAIL_COLOR if kind == 'fail' else AIDA_COLOR
                  for _n, _v, kind, _s in rows]
        bars = chart.barh(ys, [r[1] for r in rows], height=0.62,
                          color=colors, edgecolor=SURFACE, linewidth=2.0,
                          zorder=3)
        for bar, (_n, _v, kind, _s) in zip(bars, rows):
            if kind != 'ref':                 # secondary encoding: texture
                bar.set_hatch('///')
        top = max(r[1] for r in rows)
        for y, (_name, value, kind, _s) in zip(ys, rows):
            chart.text(value + top * 0.012, y, f'{value:.2f}', va='center',
                       ha='left', fontsize=8,
                       color=INK if kind != 'ref' else INK_MUTED,
                       fontweight='bold' if kind != 'ref' else 'normal')
        chart.set_yticks(ys)
        chart.set_yticklabels([r[0] for r in rows])
        for tick, (_n, _v, kind, _s) in zip(chart.get_yticklabels(), rows):
            if kind != 'ref':
                tick.set_fontweight('bold')
        chart.set_xlim(0, top * 1.15)
        chart.set_ylim(-0.6, len(rows) - 0.4)
        chart.set_xlabel(bench.axis_label)
        chart.grid(axis='x', color=GRID, linewidth=0.8, zorder=0)
        chart.tick_params(axis='y', length=0)
        for side in ('top', 'right', 'left'):
            chart.spines[side].set_visible(False)
        chart.set_title(f'AIDA vs {bench.ref_family}  (reference: table '
                        f'{args.arm_table}{", --refs" if args.refs else ""})',
                        fontsize=10, loc='left')
        kinds = {kind for _n, _v, kind, _s in rows}
        handles = [Patch(facecolor=REF_COLOR, edgecolor=SURFACE,
                         label=f'{bench.ref_family} (published)')]
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
            f'{n}: {v:.3f} {bench.metric}\n{s}' for n, v, _k, s in rows]

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

    decoder = bench.make_decoder()
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
                out.writerow(['time'] + bench.csv_header)
            out.writerow([time.strftime('%Y-%m-%d %H:%M:%S',
                                        time.localtime(run.finished))]
                         + run.csv_row())

    def tick(_frame):
        while True:
            try:
                decoder.feed(chunks.get_nowait())
            except queue.Empty:
                break
        while decoder.completed:
            log_csv(decoder.completed.pop(0))
        redraw(decoder)
        panel_text.set_text(bench.details(decoder.latest, refs,
                                          args.clock_mhz))
        title.set_text(errors[-1] if errors else decoder.status())

    tick(0)
    try:
        if args.save:
            thread.join(timeout=args.save_timeout)
            tick(0)
            figure.savefig(args.save, dpi=120)
            print(f'saved {args.save}: {decoder.status()}', flush=True)
        else:
            # keep a reference, or the animation is garbage-collected
            figure.bench_animation = FuncAnimation(
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
        print(f'no complete {bench.report} in the source', file=sys.stderr)
        return 1
    return 0
