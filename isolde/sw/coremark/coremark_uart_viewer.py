#!/usr/bin/env python3
"""Live window for coremark: AIDA's CoreMark/MHz next to Arm Cortex-M and Ibex.

    python3 coremark_uart_viewer.py --port /dev/ttyUSB3          # ZCU104, 921600
    python3 coremark_uart_viewer.py --replay log/aida_tb/0/waves-0/coremark.log
    python3 coremark_uart_viewer.py --replay uart.log --save coremark.png

Start it, then reset the board. When the firmware's report is complete
("Validation: PASS/FAIL"), its CoreMark/MHz goes into the bar chart next to
the figures Arm publishes for Cortex-M and lowRISC publishes for Ibex. The
window keeps listening; runs are grouped by I-cache state and iteration
count, so a short simulation run and a 10-second board run get separate bars.

Left: CoreMark/MHz, AIDA (measured) against the references (published).
Hover a bar for its source. Right: the latest run (cycles and
instruction-memory reads per iteration from aida_perfcnt, the CRCs, whether
the run was long enough to report). Logs from the earlier CSR-based build
(mcycle/minstret, IPC) are still understood.

CoreMark only counts as a reportable score when it runs for >= 10 s; the
firmware says whether it did (at COREMARK_CLOCK_HZ, 80 MHz by default). The
chart shows CoreMark/MHz either way, and marks short runs in the panel.

The window, the serial/replay sources, --refs, --csv and --save live in
../bench_viewer/bench_viewer.py (shared with the Dhrystone viewer).
"""
from __future__ import annotations

import re
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

# HERE = Path(__file__).resolve().parent
# sys.path.insert(0, str(HERE.parent / 'bench_viewer'))
import bench_viewer as bv  # noqa: E402  (window, sources, --refs, --csv)

# ---------------------------------------------------------------------------
# Reference cores: CoreMark/MHz
# ---------------------------------------------------------------------------
_ARM_TABLE_2020 = ('Arm Cortex-M Processor Comparison Table v3 (2020)',
                   'https://developer.arm.com/-/media/Arm%20Developer%20'
                   'Community/PDF/Cortex-A%20R%20M%20datasheets/'
                   'Arm%20Cortex-M%20Comparison%20Table_v3.pdf')
_ARM_TABLE_2022 = ('Arm Cortex-M Processor Comparison Table (2022)',
                   'https://documentation-service.arm.com/static/'
                   '61bb37962183326f2176f8cc')
_M85_LAUNCH = ('Arm Cortex-M85 launch: 6.28 CoreMark/MHz',
               'https://www.cnx-software.com/2022/04/27/arm-cortex-m85-is-'
               'faster-than-cortex-m7-offers-higher-ml-performance-than-'
               'cortex-m55/')
_IBEX = ('lowRISC Ibex README: CoreMark/MHz on Ibex Simple System',
         'https://github.com/lowRISC/ibex#configuration')

_IBEX_CORES = {
    'Ibex micro':   (0.904, _IBEX),     # RV32EC
    'Ibex small':   (2.47, _IBEX),      # RV32IMC, 3-cycle mult
    'Ibex maxperf': (3.13, _IBEX),      # RV32IMC, 1-cycle mult, BTALU, WB
}

REF_TABLES = {
    '2020': {
        'Cortex-M0':  (2.33, _ARM_TABLE_2020),
        'Cortex-M0+': (2.46, _ARM_TABLE_2020),
        'Cortex-M1':  (1.85, _ARM_TABLE_2020),
        'Cortex-M23': (2.64, _ARM_TABLE_2020),
        'Cortex-M3':  (3.34, _ARM_TABLE_2020),
        'Cortex-M4':  (3.42, _ARM_TABLE_2020),
        'Cortex-M33': (4.02, _ARM_TABLE_2020),
        'Cortex-M35P': (4.02, _ARM_TABLE_2020),
        'Cortex-M55': (4.20, _ARM_TABLE_2020),
        'Cortex-M7':  (5.01, _ARM_TABLE_2020),
        'Cortex-M85': (6.28, _M85_LAUNCH),
        **_IBEX_CORES,
    },
    '2022': {
        'Cortex-M0':  (2.33, _ARM_TABLE_2022),
        'Cortex-M0+': (2.46, _ARM_TABLE_2022),
        'Cortex-M1':  (1.83, _ARM_TABLE_2022),
        'Cortex-M23': (2.64, _ARM_TABLE_2022),
        'Cortex-M3':  (3.45, _ARM_TABLE_2022),
        'Cortex-M4':  (3.54, _ARM_TABLE_2022),
        'Cortex-M33': (4.10, _ARM_TABLE_2022),
        'Cortex-M35P': (4.10, _ARM_TABLE_2022),
        'Cortex-M55': (4.40, _ARM_TABLE_2022),
        'Cortex-M7':  (5.29, _ARM_TABLE_2022),
        'Cortex-M85': (6.28, _M85_LAUNCH),
        **_IBEX_CORES,
    },
}
DEFAULT_CORES = ('Cortex-M0', 'Cortex-M0+', 'Cortex-M23', 'Cortex-M3',
                 'Cortex-M4', 'Cortex-M33', 'Cortex-M55', 'Cortex-M7',
                 'Cortex-M85', 'Ibex small', 'Ibex maxperf')

# ---------------------------------------------------------------------------
# Decoding the firmware's report (core_main.c + coremark/core_portme.c)
# ---------------------------------------------------------------------------
BANNER = re.compile(r'AIDA CoreMark platform init \(ITERATIONS=(\d+), '
                    r'clock (\d+) Hz\)')
ICACHE = re.compile(r'Ibex I-cache\s*:\s+(enabled|disabled)')
PARAMS = re.compile(r'^(.*) run parameters for coremark\.')
FIELD = re.compile(r'^(CoreMark Size|Total ticks|Iterations|Compiler version|'
                   r'Compiler flags|Memory location|seedcrc)\s*:\s*(.*\S)\s*$')
CRC = re.compile(r'^\[(\d+)\](crclist|crcmatrix|crcstate|crcfinal)\s*:\s*'
                 r'(0x[0-9a-fA-F]+)')
CRC_ERROR = re.compile(r'^\[\d+\]ERROR! (\w+) crc (0x[0-9a-fA-F]+) - should be '
                       r'(0x[0-9a-fA-F]+)')
TYPE_ERROR = re.compile(r'^ERROR: (.*)$')
SHORT = re.compile(r'ERROR! Must execute for at least 10 secs')
CYC_PERF = re.compile(r'Cycles \(perfcnt\):\s+(\d+)')
CYC_CSR = re.compile(r'Cycles \(mcycle\):\s+(\d+)')
INSTRET = re.compile(r'Instructions \(minstret\):\s+(\d+)')
IMEM_RD = re.compile(r'Instruction-memory reads:\s+(\d+)')
# instret= only in logs from the earlier, CSR-based build of the port
RESULT = re.compile(r'COREMARK_RESULT iterations=(\d+) cycles=(\d+) '
                    r'(?:instret=(\d+) )?coremark_per_mhz_x1000=(\d+) '
                    r'clock_hz=(\d+) validated=(\d) reportable=(\d)')
VALIDATION = re.compile(r'^Validation: (PASS|FAIL)')
LOWRISC = re.compile(r'Ibex CoreMark platform init')     # lowRISC's port


@dataclass
class Run:
    iterations: int | None = None
    clock_hz: int | None = None
    icache: str | None = None
    params: str | None = None
    fields: dict = field(default_factory=dict)
    crcs: dict = field(default_factory=dict)
    cycles: int | None = None
    mcycle: int | None = None
    instret: int | None = None
    imem_reads: int | None = None
    validated: bool = False
    reportable: bool = False
    short_run: bool = False
    verdict: str | None = None
    failed_checks: list = field(default_factory=list)
    finished: float | None = None

    @property
    def score(self):
        if not self.iterations or not self.cycles:
            return None
        return self.iterations * 1e6 / self.cycles

    @property
    def key(self):
        return (self.icache, self.iterations)

    @property
    def label(self):
        return (f"AIDA Ibex (I$ {'on' if self.icache == 'enabled' else 'off'}"
                f", {self.iterations} it)")

    @property
    def seconds(self):
        if not self.cycles or not self.clock_hz:
            return None
        return self.cycles / self.clock_hz

    @property
    def note(self):
        rep = 'reportable' if self.reportable else 'not reportable (< 10 s)'
        return (f'measured on AIDA: {self.iterations} iterations, '
                f'{self.cycles} cycles, validation {self.verdict}, {rep}')

    def csv_row(self):
        return [self.label, self.icache, self.iterations, self.cycles,
                self.mcycle, self.instret, self.imem_reads,
                f'{self.score:.4f}' if self.score else '',
                self.crcs.get('crcfinal', ''), self.verdict,
                int(self.reportable), self.clock_hz,
                self.fields.get('Compiler version', ''),
                self.fields.get('Compiler flags', '')]


class Decoder:
    """Chunk-safe ASCII framing: a serial read can split a line anywhere."""

    def __init__(self):
        self.pending = bytearray()
        self.current = None          # Run being received
        self.results = {}            # Run.key -> latest completed Run
        self.latest = None           # last completed Run
        self.completed = []          # completed Runs not yet logged
        self.state = 'waiting'
        self.lowrisc = False

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
            text = raw.decode('ascii').strip()
        except UnicodeDecodeError:
            return

        banner = BANNER.search(text)
        if banner:
            self.current = Run(iterations=int(banner.group(1)),
                               clock_hz=int(banner.group(2)))
            self.state = 'measuring'
            return
        if LOWRISC.search(text):
            self.lowrisc, self.current, self.state = True, None, 'waiting'
            return
        run = self.current
        if run is None:
            return

        match = ICACHE.search(text)
        if match:
            run.icache = match.group(1)
            return
        match = PARAMS.search(text)
        if match:
            run.params = match.group(1)
            return
        match = CRC_ERROR.search(text)
        if match:
            run.failed_checks.append(f'{match.group(1)} crc {match.group(2)} '
                                     f'(expected {match.group(3)})')
            return
        match = CRC.search(text)
        if match:
            run.crcs[match.group(2)] = match.group(3)
            return
        if SHORT.search(text):
            run.short_run = True
            return
        match = TYPE_ERROR.search(text)
        if match:
            run.failed_checks.append(match.group(1))
            return
        match = FIELD.search(text)
        if match:
            run.fields[match.group(1)] = match.group(2)
            if match.group(1) == 'Total ticks':
                self.state = 'checking'
            return
        for pattern, attr in ((CYC_PERF, 'cycles'), (CYC_CSR, 'mcycle'),
                              (INSTRET, 'instret'), (IMEM_RD, 'imem_reads')):
            match = pattern.search(text)
            if match:
                setattr(run, attr, int(match.group(1)))
                return
        match = RESULT.search(text)
        if match:
            run.iterations, run.cycles = int(match.group(1)), int(match.group(2))
            if match.group(3):
                run.instret = int(match.group(3))
            run.clock_hz = int(match.group(5))
            run.validated = match.group(6) == '1'
            run.reportable = match.group(7) == '1'
            return
        match = VALIDATION.search(text)
        if match:
            run.verdict = match.group(1)
            run.finished = time.time()
            self.latest = run
            self.completed.append(run)
            if run.score is not None:
                self.results[run.key] = run
            self.current = None
            self.state = 'done'

    def status(self):
        if self.state == 'waiting':
            if self.lowrisc:
                return ("this is lowRISC's simple_system CoreMark port: "
                        'flash isolde/sw/coremark instead')
            return 'waiting for the CoreMark banner — reset the board'
        if self.state == 'measuring':
            its = self.current.iterations if self.current else '?'
            return f'running {its} CoreMark iterations…'
        if self.state == 'checking':
            return 'iterations done, receiving the CRCs and the result'
        run = self.latest
        if run is None or run.score is None:
            return 'run finished without a usable cycle count'
        rep = '' if run.reportable else '  (not reportable: < 10 s)'
        return (f'{run.label}: {run.score:.3f} CoreMark/MHz  |  '
                f'validation {run.verdict}{rep}')


# ---------------------------------------------------------------------------
# Window (shared with dhrystone21/dhry_uart_viewer.py)
# ---------------------------------------------------------------------------
def details(run, refs, clock_mhz):
    if run is None:
        return ('No complete run yet.\n\n'
                'The report ends with "Validation: PASS/FAIL";\n'
                'the bar appears when that line arrives.')
    lines = [run.label, '']
    if run.params:
        lines.append(f'run type            {run.params}')
    if run.score is None:
        lines.append('no cycle count from aida_perfcnt')
    else:
        lines += [f'iterations          {run.iterations}',
                  f'cycles (perfcnt)    {run.cycles}']
        if run.mcycle is not None:
            lines.append(f'cycles (mcycle)     {run.mcycle}')
        lines.append(f'cycles / iteration  {run.cycles / run.iterations:.1f}')
        if run.imem_reads is not None:
            lines.append(f'imem reads / iter   '
                         f'{run.imem_reads / run.iterations:.1f}')
        if run.instret:
            lines += [f'instr / iteration   {run.instret / run.iterations:.1f}',
                      f'IPC                 {run.instret / run.cycles:.3f}']
        lines.append(f'CoreMark/MHz        {run.score:.3f}')
        mhz = clock_mhz or (run.clock_hz / 1e6 if run.clock_hz else None)
        if mhz:
            lines.append(f'CoreMark @ {mhz:g} MHz   {run.score * mhz:.1f}')
            lines.append(f'run time            {run.cycles / (mhz * 1e6):.3f} s'
                         f'  ({"≥" if run.reportable else "<"} 10 s)')
    if run.crcs:
        lines += ['', 'CRCs  ' + '  '.join(
            f'{k[3:]} {v}' for k, v in run.crcs.items())]
    lines += ['', f'validation          {run.verdict}',
              f'reportable          {"yes" if run.reportable else "no"}']
    lines += [f'  ✗ {c}' for c in run.failed_checks[:6]]
    if run.score is not None and refs:
        lines += bv.ratios(run.score, refs, 'CoreMark/MHz', 'reference')
    return '\n'.join(lines)


BENCH = bv.Bench(
    name='coremark', report='CoreMark report', metric='CoreMark/MHz',
    axis_label=('CoreMark/MHz  (EEMBC CoreMark 1.0, 2K performance run; '
                'core files unmodified)'),
    ref_tables=REF_TABLES, default_table='2020', default_cores=DEFAULT_CORES,
    ref_family='Arm Cortex-M & lowRISC Ibex', make_decoder=lambda: Decoder(),
    details=lambda run, refs, clock: details(run, refs, clock),
    csv_header=['label', 'icache', 'iterations', 'cycles', 'mcycle',
                'instret', 'imem_reads', 'coremark_per_mhz', 'crcfinal', 'validation',
                'reportable', 'clock_hz', 'compiler', 'flags'],
    description=__doc__)


def main(argv=None):
    return bv.main(BENCH, argv)


if __name__ == '__main__':
    raise SystemExit(main())
