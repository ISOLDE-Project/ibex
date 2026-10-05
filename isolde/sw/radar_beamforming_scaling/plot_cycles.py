#!/usr/bin/env python3
"""Capture one complete beamforming benchmark over UART, or plot a saved log.

Only complete, validated 1/2/3-instance runs are plotted. Timing is supplied
by the target's aida_perfcnt block, never inferred from UART arrival times.
"""
from __future__ import annotations

import argparse
import csv
from dataclasses import asdict, dataclass
import json
import math
from pathlib import Path
import re
import statistics
import sys
import time

MARKER = '[BF_BENCH] '


@dataclass(frozen=True)
class Sample:
    instances: int
    repeat: int
    cycles: int
    errors: int
    worst_ulp: int


def number(fields, key, low=0, high=0xffffffff):
    value = fields.get(key, '')
    if not re.fullmatch(r'[0-9]+', value):
        raise ValueError(f'missing or invalid {key}')
    result = int(value)
    if not low <= result <= high:
        raise ValueError(f'{key} outside {low}..{high}')
    return result


class Decoder:
    """One framed run; refuse duplicate samples, failed or partial runs."""
    def __init__(self, allow_host_mock=False):
        self.allow_host_mock = allow_host_mock
        self.meta = None
        self.samples = {}
        self.done = False
        self.pending = bytearray()

    def line(self, raw):
        if b'[BF_BENCH]' not in raw:
            return
        try:
            text = raw.decode('ascii').strip()
        except UnicodeDecodeError as exc:
            raise ValueError('non-ASCII benchmark record') from exc
        if text.count('[BF_BENCH]') != 1 or MARKER not in text:
            raise ValueError('malformed benchmark record')
        payload = text.split(MARKER, 1)[1].split()
        if not payload:
            raise ValueError('empty benchmark record')
        kind, *tokens = payload
        fields = {}
        for token in tokens:
            if token.count('=') != 1:
                raise ValueError('malformed benchmark field')
            key, value = token.split('=')
            if not key or not value or key in fields:
                raise ValueError('empty or duplicate benchmark field')
            fields[key] = value
        if self.done:
            raise ValueError('multiple runs or records after END; use a log with one run')
        if kind == 'BEGIN':
            if self.meta is not None:
                raise ValueError('new BEGIN before END; capture a fresh run')
            if fields.get('version') != '2':
                raise ValueError('expected benchmark version 2 (aida_perfcnt); rebuild with the corrected firmware')
            if not re.fullmatch('[0-9a-fA-F]{16}', fields.get('case', '')):
                raise ValueError('invalid vector case ID')
            for key, expected in [('rows', 36), ('inner', 16), ('cols', 16), ('block_rows', 12)]:
                if number(fields, key) != expected:
                    raise ValueError(f'unsupported workload: {key}')
            number(fields, 'repeats', 1, 10000)
            number(fields, 'warmups', 0, 10000)
            number(fields, 'tiles', 3)
            if (fields.get('counter') != 'aida_perfcnt' or
                    fields.get('counter_bits') != '32' or fields.get('scope') != 'end_to_end'):
                raise ValueError('unsupported counter or timing scope')
            source = fields.get('source')
            if source not in ('hardware_counter', 'host_mock'):
                raise ValueError('unknown measurement source')
            if source == 'host_mock' and not self.allow_host_mock:
                raise ValueError('host mock is not FPGA timing; --allow-host-mock is for tests only')
            self.meta = fields
        elif kind == 'FAIL':
            raise ValueError(f'firmware failure: {fields.get("reason", "unspecified")}')
        elif self.meta is None:
            raise ValueError('benchmark record before BEGIN; start capture before resetting FPGA')
        elif kind == 'SAMPLE':
            instances = number(fields, 'instances', 1, 3)
            repeat = number(fields, 'repeat', 0, int(self.meta['repeats']) - 1)
            hi, lo = number(fields, 'cycles_hi'), number(fields, 'cycles_lo')
            if hi != 0:
                raise ValueError('aida_perfcnt exposes a 32-bit result; cycles_hi must be zero')
            cycles = (hi << 32) | lo
            errors, worst = number(fields, 'errors'), number(fields, 'worst_ulp')
            if fields.get('status') != 'PASS' or errors or not cycles:
                raise ValueError('failed validation or zero cycle count')
            key = (instances, repeat)
            if key in self.samples:
                raise ValueError(f'duplicate sample {key}')
            self.samples[key] = Sample(instances, repeat, cycles, errors, worst)
        elif kind == 'END':
            expected = 3 * int(self.meta['repeats'])
            if fields.get('status') != 'PASS':
                raise ValueError('firmware did not finish with PASS')
            if number(fields, 'samples') != expected or len(self.samples) != expected:
                raise ValueError(f'incomplete run: {len(self.samples)}/{expected} samples')
            self.done = True
        else:
            raise ValueError(f'unknown benchmark record {kind}')

    def feed(self, chunk):
        for byte in chunk:
            if byte == 10:
                self.line(bytes(self.pending))
                self.pending.clear()
            else:
                self.pending.append(byte)
                if len(self.pending) > 4096:
                    raise ValueError('UART line longer than 4096 bytes')

    def finish(self):
        # Permit a saved text log without a final newline, but still require END.
        if self.pending:
            self.line(bytes(self.pending))
            self.pending.clear()
        if not self.done:
            raise ValueError('incomplete run: missing BEGIN, samples, or successful END')
        return self


def read_log(path, allow_host_mock=False):
    decoder = Decoder(allow_host_mock)
    with path.open('rb') as stream:
        while chunk := stream.read(8192):
            decoder.feed(chunk)
    return decoder.finish()


def open_serial(port, baud):
    try:
        import serial
    except ImportError as exc:
        raise RuntimeError('Live capture needs pyserial: python3 -m pip install pyserial') from exc
    device = serial.Serial(port=None, baudrate=baud, timeout=0.1,
                           bytesize=serial.EIGHTBITS, parity=serial.PARITY_NONE,
                           stopbits=serial.STOPBITS_ONE, xonxoff=False,
                           rtscts=False, dsrdtr=False, exclusive=True)
    device.dtr = False
    device.rts = False
    device.port = port
    device.open()
    return device


def capture_uart(args):
    decoder = Decoder(args.allow_host_mock)
    args.capture.parent.mkdir(parents=True, exist_ok=True)
    # Retain raw bytes even on validation failure, timeout, or Ctrl+C.
    with open_serial(args.port, args.baud) as device, args.capture.open('wb') as capture:
        print('UART open; start/reset the FPGA application now.', flush=True)
        deadline = time.monotonic() + args.timeout
        while not decoder.done:
            if time.monotonic() >= deadline:
                raise TimeoutError('capture timed out before a complete run; check port/baud and reset FPGA')
            chunk = device.read(512)
            if chunk:
                capture.write(chunk)
                capture.flush()
                decoder.feed(chunk)
    return decoder.finish()


def summarize(decoder):
    rows = []
    for instances in (1, 2, 3):
        values = [s.cycles for s in decoder.samples.values() if s.instances == instances]
        rows.append(dict(instances=instances, samples=len(values),
                         median_cycles=statistics.median(values),
                         min_cycles=min(values), max_cycles=max(values)))
    baseline = rows[0]['median_cycles']
    for row in rows:
        row['speedup_vs_1'] = baseline / row['median_cycles']
    return rows


def write_results(decoder, out_dir, label, show=False):
    import matplotlib
    if not show:
        matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    from matplotlib.ticker import StrMethodFormatter

    out_dir.mkdir(parents=True, exist_ok=True)
    rows = summarize(decoder)
    with (out_dir / 'cycles.csv').open('w', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=list(asdict(next(iter(decoder.samples.values())))))
        writer.writeheader()
        writer.writerows(asdict(decoder.samples[key]) for key in sorted(decoder.samples))
    (out_dir / 'summary.json').write_text(json.dumps(dict(
        label=label, metadata=decoder.meta, summary=rows,
        timing='Platform aida_perfcnt cycles: dispatch + upload + GEMM + wait + download; '
               'includes timer/fence overhead; excludes validation and UART printing.'), indent=2) + '\n')

    medians = [r['median_cycles'] for r in rows]
    errors = [[r['median_cycles'] - r['min_cycles'] for r in rows],
              [r['max_cycles'] - r['median_cycles'] for r in rows]]
    with plt.rc_context({'font.family': 'DejaVu Sans', 'font.size': 11,
                         'axes.spines.top': False, 'axes.spines.right': False}):
        fig, ax = plt.subplots(figsize=(9, 6), layout='constrained')
        bars = ax.bar([1, 2, 3], medians, width=.58, color=['#235789', '#178f86', '#d67c28'],
                      yerr=errors, capsize=6, error_kw={'elinewidth': 1.5})
        for bar, row in zip(bars, rows):
            ax.annotate(f'{row["median_cycles"]:,.0f} cycles\n{row["speedup_vs_1"]:.2f}× vs 1',
                        (bar.get_x() + bar.get_width()/2, row['max_cycles']),
                        xytext=(0, 9), textcoords='offset points', ha='center', va='bottom')
        ax.set_xticks([1, 2, 3], ['1 instance', '2 instances', '3 instances'])
        ax.set(xlabel='Active RedMulE instances', ylabel='Platform cycles per complete 36-beam scan',
               ylim=(0, max(r['max_cycles'] for r in rows) * 1.28))
        ax.yaxis.set_major_formatter(StrMethodFormatter('{x:,.0f}'))
        ax.set_axisbelow(True)
        ax.grid(axis='y', alpha=.2)
        mock = decoder.meta['source'] == 'host_mock'
        heading = 'HOST MOCK — NOT FPGA MEASUREMENTS' if mock else 'Beamforming execution cycles'
        fig.suptitle(heading, fontsize=17, fontweight='bold')
        ax.set_title(f'{label}\n36 beams × 16 antennas × 16 range bins', fontsize=11, pad=14)
        fig.supxlabel(f'Median of {decoder.meta["repeats"]} scans; whiskers show min–max. '
                      f'{decoder.meta["warmups"]} warm-up(s) per configuration excluded.\n'
                      f'Includes transfers and accelerator execution. Case {decoder.meta["case"]}.',
                      fontsize=9)
        fig.savefig(out_dir / 'cycles.png', dpi=180)
        fig.savefig(out_dir / 'cycles.svg')
        if show:
            plt.show()
        plt.close(fig)
    return rows


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--log', type=Path, help='saved UART log containing exactly one run')
    source.add_argument('--port', help='serial device, e.g. /dev/ttyUSB3')
    parser.add_argument('--baud', type=int, default=921600)
    parser.add_argument('--capture', type=Path, help='raw serial capture (default: OUT_DIR/uart.log)')
    parser.add_argument('--timeout', type=float, default=120, help='total live-capture timeout, seconds')
    parser.add_argument('--out-dir', type=Path, default=Path('results/scaling'))
    parser.add_argument('--label', default='UART measurement', help='board/bitstream label; does not verify origin')
    parser.add_argument('--show', action='store_true', help='also open an interactive plot window')
    parser.add_argument('--allow-host-mock', action='store_true', help='testing only; graph will be labelled HOST MOCK')
    args = parser.parse_args(argv)
    if args.baud <= 0 or not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error('baud and timeout must be positive')
    if args.log and args.capture:
        parser.error('--capture is only for --port')
    if args.port and args.capture is None:
        args.capture = args.out_dir / 'uart.log'
    reserved = {(args.out_dir / name).resolve() for name in ('cycles.png', 'cycles.svg', 'cycles.csv', 'summary.json')}
    if (args.log and args.log.resolve() in reserved) or (args.capture and args.capture.resolve() in reserved):
        parser.error('input/capture path must differ from generated result files')
    try:
        decoder = read_log(args.log, args.allow_host_mock) if args.log else capture_uart(args)
        rows = write_results(decoder, args.out_dir, args.label, args.show)
    except KeyboardInterrupt:
        print('Capture interrupted; no graph generated. Raw capture retained.', file=sys.stderr)
        return 130
    except (OSError, ValueError, RuntimeError, ImportError) as exc:
        print(f'Error: {exc}', file=sys.stderr)
        return 1
    print('instances  samples  median cycles  min cycles  max cycles  speedup')
    for row in rows:
        print(f'{row["instances"]:9d}  {row["samples"]:7d}  {row["median_cycles"]:13,.0f}  '
              f'{row["min_cycles"]:10,d}  {row["max_cycles"]:10,d}  {row["speedup_vs_1"]:.3f}x')
    print(f'Wrote {args.out_dir / "cycles.png"}, cycles.svg, cycles.csv, summary.json')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
