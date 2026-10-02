import importlib.util
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

import numpy as np
import beamforming as bf

APP = Path(__file__).resolve().parents[1]
ROOT = APP.parents[2]


class BeamformingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data = bf.prepare()

    def test_target_directions_and_complex_identity(self):
        d = self.data
        ar, ai, br, bi = (d[k].astype(float) for k in ('ar', 'ai', 'br', 'bi'))
        split = (ar @ br - ai @ bi) + 1j*(ar @ bi + ai @ br)
        np.testing.assert_allclose(split, d['quantized'], atol=2e-15)
        c = d['cr'].astype(float) + 1j*d['ci'].astype(float)
        for angle, range_bin, _, _ in bf.TARGETS:
            self.assertEqual(bf.ANGLES[np.argmax(abs(c[:, range_bin]))], angle)
        self.assertLess(np.max(np.abs(c-d['ideal'])), .003)

    def test_repository_golden_model(self):
        source = APP.parent / 'scripts/complex_gemm/complex_gemm.py'
        if not source.exists():
            self.skipTest('upstream reference only present inside the Ibex checkout')
        spec = importlib.util.spec_from_file_location('upstream', source)
        upstream = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(upstream)
        d = self.data
        a = d['ar'].astype(float) + 1j*d['ai'].astype(float)
        b = d['br'].astype(float) + 1j*d['bi'].astype(float)
        cr, ci = upstream.tiled_complex_gemm(a.tolist(), b.tolist(), 12, 16, 16)
        np.testing.assert_array_equal(np.array(cr, dtype=np.float16), d['cr'])
        np.testing.assert_array_equal(np.array(ci, dtype=np.float16), d['ci'])

    def test_onnx_export_and_portable_execution(self):
        with tempfile.TemporaryDirectory() as folder:
            result = bf.export_onnx(Path(folder), self.data)
            self.assertLess(result['portable_onnx_max_complex_error'], 2e-7)

    def test_reject_corrupt_or_incomplete_logs(self):
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / 'bad.log'
            log.write_text(f"[RADAR] case={self.data['case_id']} mode=runtime3 rows=36 cols=16\n"
                           '[BF16] 0 0000 0000\n[RADAR] PASSED\n')
            with self.assertRaisesRegex(ValueError, 'incomplete'):
                bf.parse_log(log, self.data['case_id'])
            with self.assertRaisesRegex(ValueError, 'metadata'):
                bf.parse_log(log, 'wrong-case')
            log.write_text(log.read_text() + '[BF16] 0 0000 0000\n')
            with self.assertRaisesRegex(ValueError, 'duplicate'):
                bf.parse_log(log, self.data['case_id'])
        bad = self.data['cr'].copy()
        bad[0, 0] = np.nan
        self.assertEqual(bf.compare(bad, self.data['ci'], self.data)['errors'], 1)

    def test_runtime_schedule_and_firmware_host_mock(self):
        with tempfile.TemporaryDirectory() as folder:
            tmp = Path(folder)
            base = shlex.split(os.environ.get('CC', 'cc')) + [
                '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror', '-ffp-contract=off',
                '-I' + str(APP / 'tests/shim'), '-I' + str(ROOT / 'isolde/system'),
                '-I' + str(APP), '-I' + str(APP / 'inc'),
                str(APP / 'beamform_runtime.c'), str(APP / 'tests/mock_runtime.c')]
            # Standalone extracted bundles also include the exact upstream ABI header.
            for name, source in [('schedule', APP / 'tests/schedule_test.c'),
                                 ('firmware', APP / 'main.c')]:
                executable = tmp / name
                subprocess.run(base + [str(source), '-o', str(executable)], check=True)
                completed = subprocess.run([str(executable)], check=True,
                                           text=True, capture_output=True)
                if name == 'firmware':
                    log = tmp / 'host_mock.log'
                    log.write_text(completed.stdout)
                    real, imag, mode = bf.parse_log(log, self.data['case_id'])
                    self.assertEqual(mode, 'runtime3')
                    self.assertEqual(bf.compare(real, imag, self.data)['errors'], 0)
                    # Preserve a clearly labelled reproducible test artifact.
                    (APP / 'results').mkdir(exist_ok=True)
                    (APP / 'results/host_mock.log').write_text(
                        'HOST SOFTWARE MOCK - NOT VERILATOR OR RTL OUTPUT\n' + completed.stdout)


if __name__ == '__main__':
    unittest.main()
