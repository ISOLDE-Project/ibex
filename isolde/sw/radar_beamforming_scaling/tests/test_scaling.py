import contextlib
import io
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import plot_cycles as plot

APP = Path(__file__).resolve().parents[1]


class ScalingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.tmp.cleanup)
        cls.folder = Path(cls.tmp.name)
        cls.base = shlex.split(os.environ.get('CC', 'cc')) + [
            '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror', '-ffp-contract=off',
            '-DBF_BENCH_HOST_TEST', '-I' + str(APP / 'tests/shim'), '-I' + str(APP),
            str(APP / 'tests/mock_runtime.c')]
        cls.firmware = cls.compile('firmware', APP / 'main.c')
        run = subprocess.run([str(cls.firmware)], check=True, capture_output=True)
        cls.raw = run.stdout

    @classmethod
    def compile(cls, name, source, flags=()):
        output = cls.folder / name
        subprocess.run(cls.base + list(flags) + [str(source), '-o', str(output)], check=True)
        return output

    def decode(self, raw=None, allow=True):
        decoder = plot.Decoder(allow_host_mock=allow)
        decoder.feed(self.raw if raw is None else raw)
        return decoder.finish()

    def test_fixed_workload_schedules_and_golden_outputs(self):
        binary = self.compile('schedule', APP / 'tests/schedule_test.c')
        run = subprocess.run([str(binary)], check=True, capture_output=True, text=True)
        self.assertIn('PASS:', run.stdout)

    def test_firmware_all_repeats_and_unsigned_cycle_roundtrip(self):
        decoder = self.decode()
        self.assertEqual(len(decoder.samples), 15)
        self.assertEqual(decoder.meta['case'], '1ba8e226c32b767c')
        self.assertEqual(decoder.meta['counter'], 'aida_perfcnt')
        self.assertEqual(decoder.meta['counter_bits'], '32')
        self.assertTrue(all(s.cycles == (1 << 31) + 123 for s in decoder.samples.values()))
        self.assertTrue(all(s.errors == 0 and s.worst_ulp == 0 for s in decoder.samples.values()))
        self.assertEqual(list(decoder.samples)[:6], [(1, 0), (2, 0), (3, 0), (2, 1), (3, 1), (1, 1)])

    def test_chunking_crlf_and_timestamp_prefixes(self):
        raw = b'boot message\r\n' + b''.join(b'[12:34] ' + line + b'\r\n' for line in self.raw.splitlines())
        decoder = plot.Decoder(True)
        for byte in raw:
            decoder.feed(bytes([byte]))
        self.assertEqual(len(decoder.finish().samples), 15)
        self.assertEqual(len(self.decode(self.raw.rstrip()).samples), 15)

    def test_host_timing_refused_by_default(self):
        with self.assertRaisesRegex(ValueError, 'not FPGA timing'):
            self.decode(allow=False)

    def test_reject_partial_duplicate_failed_or_mixed_runs(self):
        lines = self.raw.splitlines(keepends=True)
        cases = [
            b''.join(lines[:-1]),
            b''.join(lines[:1] + lines[2:]),
            b''.join(lines[:2] + lines[1:]),
            self.raw.replace(b'errors=0', b'errors=1', 1),
            self.raw.replace(b'status=PASS', b'status=FAIL', 1),
            self.raw.replace(b'cycles_hi=0 cycles_lo=2147483771', b'cycles_hi=0 cycles_lo=0', 1),
            self.raw.replace(b'cycles_hi=0', b'cycles_hi=1', 1),
            self.raw.replace(b'cycles_lo=2147483771', b'cycles_lo=4294967296', 1),
            self.raw.replace(b'repeat=0', b'repeat=5', 1),
            self.raw.replace(b'instances=1', b'instances=4', 1),
            self.raw.replace(b'rows=36', b'rows=24', 1),
            self.raw.replace(b'counter=aida_perfcnt', b'counter=mcycle', 1),
            self.raw.replace(b'version=2', b'version=1', 1),
            self.raw.replace(b'instances=1', b'instances=1 instances=1', 1),
            self.raw + self.raw,
            b''.join(lines[1:]),
        ]
        for raw in cases:
            with self.subTest(raw=raw[:90]):
                with self.assertRaises(ValueError):
                    self.decode(raw)

    def test_summary_statistics(self):
        decoder = self.decode()
        for instances in (1, 2, 3):
            for repeat in range(5):
                decoder.samples[instances, repeat] = plot.Sample(instances, repeat, 1200 // instances + repeat * 10, 0, 0)
        rows = plot.summarize(decoder)
        self.assertEqual([r['median_cycles'] for r in rows], [1220, 620, 420])
        self.assertEqual(rows[1]['min_cycles'], 600)
        self.assertEqual(rows[1]['max_cycles'], 640)
        self.assertAlmostEqual(rows[2]['speedup_vs_1'], 1220/420)

    def test_firmware_refuses_missing_tiles(self):
        binary = self.compile('two_tiles', APP / 'main.c', ['-DMOCK_TILE_COUNT=2'])
        run = subprocess.run([str(binary)], capture_output=True)
        self.assertEqual(run.returncode, 1)
        self.assertIn(b'reason=insufficient_tiles', run.stdout)
        self.assertNotIn(b'SAMPLE', run.stdout)

    def test_corrupt_warmup_fails_before_samples(self):
        binary = self.compile('bad_warmup', APP / 'main.c', ['-DMOCK_CORRUPT_OUTPUT'])
        run = subprocess.run([str(binary)], capture_output=True)
        self.assertEqual(run.returncode, 1)
        self.assertIn(b'reason=warmup_validation', run.stdout)
        self.assertNotIn(b'SAMPLE', run.stdout)

    def test_zero_warmups_and_measured_validation_failure(self):
        binary = self.compile('no_warmup', APP / 'main.c', ['-DBF_BENCH_WARMUPS=0', '-DBF_BENCH_REPEATS=1'])
        run = subprocess.run([str(binary)], check=True, capture_output=True)
        self.assertEqual(len(self.decode(run.stdout).samples), 3)
        binary = self.compile('bad_measured', APP / 'main.c', ['-DBF_BENCH_WARMUPS=0', '-DMOCK_CORRUPT_OUTPUT'])
        run = subprocess.run([str(binary)], capture_output=True)
        self.assertEqual(run.returncode, 1)
        self.assertIn(b'SAMPLE instances=1', run.stdout)
        with self.assertRaises(ValueError):
            self.decode(run.stdout)

    def test_cli_creates_graph_and_preserves_exact_samples(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            log = folder / 'mock.log'
            log.write_bytes(self.raw)
            out = folder / 'plot'
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(plot.main(['--log', str(log), '--out-dir', str(out), '--allow-host-mock']), 0)
            self.assertTrue((out / 'cycles.png').read_bytes().startswith(b'\x89PNG'))
            self.assertIn('HOST MOCK', (out / 'cycles.svg').read_text())
            self.assertEqual(len((out / 'cycles.csv').read_text().splitlines()), 16)
            data = json.loads((out / 'summary.json').read_text())
            self.assertEqual(data['metadata']['source'], 'host_mock')
            self.assertEqual(data['summary'][0]['median_cycles'], (1 << 31) + 123)
            log.write_bytes(self.raw.replace(b'status=PASS', b'status=FAIL'))
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(plot.main(['--log', str(log), '--out-dir', str(folder/'bad'), '--allow-host-mock']), 1)
            self.assertFalse((folder / 'bad').exists())

    def test_serial_capture_with_chunked_test_transport(self):
        # Exercise capture without a UART device; never treat this as FPGA data.
        class Transport:
            def __init__(self, raw):
                self.data = io.BytesIO(raw)
            def __enter__(self):
                return self
            def __exit__(self, *args):
                return False
            def read(self, size):
                return self.data.read(17)
        with tempfile.TemporaryDirectory() as tmp:
            capture = Path(tmp) / 'capture.log'
            args = SimpleNamespace(port='mock', baud=921600, capture=capture,
                                   timeout=5, allow_host_mock=True)
            with patch.object(plot, 'open_serial', return_value=Transport(self.raw)), contextlib.redirect_stdout(io.StringIO()):
                decoder = plot.capture_uart(args)
            self.assertEqual(capture.read_bytes(), self.raw)
            self.assertEqual(len(decoder.samples), 15)


if __name__ == '__main__':
    unittest.main()
