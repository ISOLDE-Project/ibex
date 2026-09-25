#!/usr/bin/env python3
"""Host tests for the radar_attention firmware.

Builds the real runtime against the strict host mock and checks that the C
reproduces the Python FP16 reference exactly, that the schedule costs what the
model's shape says it should, and that the dataram budget assert actually
fires when the configuration does not fit.

None of this simulates RTL.  It does not model DMA bank overlap, XIF,
interrupts, the soft-float ABI or cycle timing.
"""
from __future__ import annotations

import contextlib
import io
import os
import re
import shlex
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
APP = HERE.parent
ROOT = APP.parent.parent.parent
BEAMFORM = APP.parent / 'radar_beamforming'

sys.path.insert(0, str(APP))
import radar_scene as rs        # noqa: E402
import tformer as tf            # noqa: E402
import tformer_viewer as viewer  # noqa: E402

BASE_FLAGS = ['-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
              '-ffp-contract=off']


def compiler():
    return shlex.split(os.environ.get('CC', 'cc'))


def includes(header_dir):
    return ['-I' + str(APP / 'tests/shim'), '-I' + str(ROOT / 'isolde/system'),
            '-I' + str(APP), '-I' + str(APP / header_dir)]


def build(destination, sources, header_dir='inc', defines=(), extra=()):
    command = (compiler() + BASE_FLAGS + includes(header_dir) + list(extra)
               + [f'-D{d}' for d in defines]
               + [str(s) for s in sources] + ['-o', str(destination)])
    return subprocess.run(command, capture_output=True, text=True)


RUNTIME = [APP / 'tformer_runtime.c', APP / 'tformer_features.c',
           APP / 'tests/mock_runtime.c']


class TestGeneratedHeaders(unittest.TestCase):
    """The C constants are generated from the Python, so they cannot drift."""

    def setUp(self):
        self.text = (APP / 'inc/tformer_features_const.h').read_text()

    def test_log_table_matches_the_python_definition(self):
        body = self.text.split('tf_log2_lut[TF_LOG2_LUT_SIZE] = {')[1]
        values = [int(v) for v in re.findall(r'-?\d+', body.split('};')[0])]
        np.testing.assert_array_equal(np.array(values), rs.LOG2_LUT)

    def test_angle_group_edges_match(self):
        body = self.text.split('tf_angle_group_edge[')[1].split('= {')[1]
        values = [int(v) for v in re.findall(r'\d+', body.split('};')[0])]
        np.testing.assert_array_equal(np.array(values), rs.ANGLE_GROUP_EDGES)

    def test_floor_is_the_power_of_two_the_firmware_relies_on(self):
        self.assertIn(f'#define TF_LOG_FLOOR_Q ({rs.LOG_FLOOR_Q})', self.text)
        self.assertIn(f'#define TF_LOG_SCALE_SHIFT {rs.LOG_SCALE_SHIFT}u',
                      self.text)
        self.assertEqual(rs.LOG_FLOOR_Q, -(1 << rs.LOG_SCALE_SHIFT))


class TestFeatureFrontEnd(unittest.TestCase):
    """Drive the C directly with cases the exported vectors do not contain."""

    @classmethod
    def setUpClass(cls):
        cls.folder = tempfile.TemporaryDirectory()
        cls.binary = Path(cls.folder.name) / 'feature_test'
        result = build(cls.binary, [APP / 'tformer_features.c',
                                    APP / 'tests/feature_test.c'])
        if result.returncode:
            raise AssertionError(result.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.folder.cleanup()

    def run_c(self, mode, words):
        text = '\n'.join(f'{int(w):04x}' for w in np.asarray(words).ravel())
        done = subprocess.run([str(self.binary), mode], input=text,
                              capture_output=True, text=True, check=True)
        return np.array([int(line, 16) for line in done.stdout.split()],
                        dtype=np.uint16)

    def test_profiles_match_python_bit_for_bit(self):
        rng = np.random.default_rng(3)
        for _ in range(8):
            cr = rng.standard_normal((rs.N_BEAMS, rs.N_BINS)).astype(np.float16)
            ci = rng.standard_normal((rs.N_BEAMS, rs.N_BINS)).astype(np.float16)
            got = self.run_c('profiles', np.concatenate(
                [cr.view(np.uint16).ravel(), ci.view(np.uint16).ravel()]))
            mag = rs.magnitude_proxy(cr, ci)
            bearing, ranges = rs.marginal_profiles(mag)
            np.testing.assert_array_equal(got[:16], bearing.view(np.uint16))
            np.testing.assert_array_equal(got[16:], ranges.view(np.uint16))

    def test_normalise_matches_python_bit_for_bit(self):
        rng = np.random.default_rng(9)
        cases = [
            np.abs(rng.standard_normal((rs.N_FRAMES, 32))).astype(np.float16),
            np.full((rs.N_FRAMES, 32), np.float16(1.0)),
            np.zeros((rs.N_FRAMES, 32), dtype=np.float16),
            # Full dynamic range, so the floor clamp is actually exercised.
            np.logspace(-8, 1, rs.N_FRAMES * 32).astype(np.float16).reshape(
                rs.N_FRAMES, 32),
        ]
        single = np.zeros((rs.N_FRAMES, 32), dtype=np.float16)
        single[3, 7] = np.float16(2.0)
        cases.append(single)
        for values in cases:
            got = self.run_c('normalise', values.view(np.uint16))
            expected = rs.log_normalise(values).view(np.uint16).ravel()
            np.testing.assert_array_equal(got, expected)

    def test_normalised_features_are_exact_multiples_of_the_scale(self):
        """The power-of-two floor is what removes the division; check it."""
        rng = np.random.default_rng(11)
        values = np.abs(rng.standard_normal((rs.N_FRAMES, 32))).astype(np.float16)
        got = self.run_c('normalise', values.view(np.uint16))
        scaled = got.view(np.float16).astype(np.float64) * 2 ** rs.LOG_SCALE_SHIFT
        np.testing.assert_array_equal(scaled, np.round(scaled))
        self.assertLessEqual(scaled.max(), 1 << rs.LOG_SCALE_SHIFT)


class TestSchedule(unittest.TestCase):
    def test_schedule_and_numerics_against_the_mock(self):
        with tempfile.TemporaryDirectory() as folder:
            binary = Path(folder) / 'schedule'
            result = build(binary, RUNTIME + [APP / 'tests/schedule_test.c'])
            self.assertEqual(result.returncode, 0, result.stderr)
            done = subprocess.run([str(binary)], capture_output=True,
                                  text=True, check=True)
            self.assertIn('PASSED', done.stdout)

    def test_firmware_encoder_mode(self):
        with tempfile.TemporaryDirectory() as folder:
            binary = Path(folder) / 'firmware'
            result = build(binary, RUNTIME + [APP / 'main.c'],
                           defines=['TF_DUMP=0'])
            self.assertEqual(result.returncode, 0, result.stderr)
            done = subprocess.run([str(binary)], capture_output=True,
                                  text=True, check=True)
            self.assertIn('[TFORMER] errors=0 worst_ulp=0', done.stdout)
            self.assertIn('[TFORMER] PASSED', done.stdout)
            (APP / 'results').mkdir(exist_ok=True)
            (APP / 'results/host_mock_encoder.log').write_text(
                'HOST SOFTWARE MOCK - NOT VERILATOR OR RTL OUTPUT\n'
                + done.stdout)


class TestChain(unittest.TestCase):
    """The beamformer feeding the encoder, in one run, on the host mock."""

    HEADERS = 'inc'
    WEIGHTS = 'tformer_weights_l1.h'

    def setUp(self):
        if not (APP / self.HEADERS / self.WEIGHTS).exists():
            self.skipTest('run: make model-chain')

    def test_chain_reproduces_the_features_exactly(self):
        with tempfile.TemporaryDirectory() as folder:
            binary = Path(folder) / 'chain'
            result = build(binary,
                           RUNTIME + [BEAMFORM / 'beamform_runtime.c',
                                      APP / 'main.c'],
                           header_dir=self.HEADERS,
                           defines=['TF_DUMP=0', 'TF_CHAIN=1',
                                    f'TF_WEIGHTS_HEADER=\"{self.WEIGHTS}\"'],
                           extra=['-I' + str(BEAMFORM)])
            self.assertEqual(result.returncode, 0, result.stderr)
            done = subprocess.run([str(binary)], capture_output=True,
                                  text=True, check=True)
            # Integer front end: anything but an exact match is a bug.
            self.assertIn('feature_errors=0', done.stdout)
            self.assertIn('[TFORMER] errors=0 worst_ulp=0', done.stdout)
            self.assertIn('[TFORMER] PASSED', done.stdout)
            (APP / 'results').mkdir(exist_ok=True)
            (APP / 'results/host_mock_chain.log').write_text(
                'HOST SOFTWARE MOCK - NOT VERILATOR OR RTL OUTPUT\n'
                + done.stdout)


class TestMemoryBudget(unittest.TestCase):
    """The assert in main.c must reject a configuration that cannot fit."""

    def test_two_layer_chain_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            result = build(Path(folder) / 'over',
                           RUNTIME + [BEAMFORM / 'beamform_runtime.c',
                                      APP / 'main.c'],
                           header_dir='inc',
                           defines=['TF_DUMP=0', 'TF_CHAIN=1'],
                           extra=['-I' + str(BEAMFORM)])
            self.assertNotEqual(result.returncode, 0,
                                'the 2-layer chain build must not fit dataram')
            self.assertIn('exceeds dataram', result.stderr)


class TestMockCatchesBugs(unittest.TestCase):
    """A test double that never fails is worthless; show that it does."""

    def test_missing_barrier_is_rejected(self):
        source = '''
#include <stdint.h>
#include <bsp/onnx_redmule_runtime.h>
static uint16_t buffer[256];
int main(void) {
  uint32_t x = omrm_addr_start(0, 0);
  uint32_t w = omrm_upload_f16(0, x, buffer, 192, 0);
  uint32_t y = omrm_upload_f16(0, w, buffer, 256, 0);
  omrm_zero_f16(0, y, 192);
  omrm_gemm_f16_16_12_16(0, x, w, y);
  omrm_upload_f16(0, x, buffer, 192, 0);   /* no wait: must abort */
  return 0;
}
'''
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'bad.c'
            path.write_text(source)
            binary = Path(folder) / 'bad'
            result = build(binary, [APP / 'tests/mock_runtime.c', path])
            self.assertEqual(result.returncode, 0, result.stderr)
            done = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertNotEqual(done.returncode, 0,
                                'the mock accepted an in-flight overwrite')


def header_array(text, name):
    body = text.split(f'{name}[')[1].split('= {')[1].split('};')[0]
    return np.array([int(v, 16) for v in re.findall(r'0x([0-9a-f]{4})', body)],
                    dtype=np.uint16)


class TestExportedCase(unittest.TestCase):
    """The vectors header must come from the data pipeline, not from anywhere
    else: regenerate the case and compare."""

    def setUp(self):
        self.text = (APP / 'inc/tformer_vectors.h').read_text()

    def test_features_regenerate_from_the_scene_generator(self):
        seed = int(re.search(r'--case seed (\d+)', self.text).group(1)) \
            if '--case seed' in self.text else 4242
        label = int(re.search(r'#define TF_TRUE_CLASS (\d+)u',
                              self.text).group(1))
        sequence = rs.make_sequence(np.random.default_rng(seed), label)
        expected = np.stack([sequence['features'][:, :16],
                             sequence['features'][:, 16:]])
        np.testing.assert_array_equal(header_array(self.text, 'tf_features'),
                                      expected.view(np.uint16).ravel())

    def test_chain_snapshots_regenerate_too(self):
        label = int(re.search(r'#define TF_TRUE_CLASS (\d+)u',
                              self.text).group(1))
        sequence = rs.make_sequence(np.random.default_rng(4242), label)
        snapshots = np.ascontiguousarray(sequence['snapshots'].real,
                                         dtype=np.float16)
        np.testing.assert_array_equal(header_array(self.text, 'tf_br'),
                                      snapshots.view(np.uint16).ravel())

    def test_pool_matrix_really_averages_the_frames(self):
        pool = header_array((APP / 'inc/tformer_weights.h').read_text(),
                            'tf_pool').view(np.float16).reshape(12, 16)
        np.testing.assert_allclose(pool[:, :rs.N_FRAMES].astype(np.float64),
                                   1.0 / rs.N_FRAMES, rtol=1e-3)
        np.testing.assert_array_equal(pool[:, rs.N_FRAMES:], 0)

    def test_fp16_reference_and_gemm_agree_with_radar_beamforming(self):
        """tformer.gemm must be the same arithmetic radar_beamforming uses."""
        rng = np.random.default_rng(5)
        x = rng.standard_normal((12, 16)).astype(np.float16)
        w = rng.standard_normal((16, 16)).astype(np.float16)
        np.testing.assert_array_equal(
            tf.gemm(x, w).view(np.uint16),
            rs.real_accumulate_batched(x, w[None])[0].view(np.uint16))


if __name__ == '__main__':
    unittest.main(verbosity=2)


class TestViewer(unittest.TestCase):
    """The UART parser must reject bad logs, not just plot good ones."""

    @classmethod
    def setUpClass(cls):
        cls.folder = tempfile.TemporaryDirectory()
        binary = Path(cls.folder.name) / 'fw'
        result = build(binary, RUNTIME + [APP / 'main.c'])
        if result.returncode:
            raise AssertionError(result.stderr)
        cls.log = subprocess.run([str(binary)], capture_output=True,
                                 text=True).stdout
        cls.golden = viewer.load_golden(APP / 'inc')

    @classmethod
    def tearDownClass(cls):
        cls.folder.cleanup()

    def test_a_good_log_parses_and_matches(self):
        received = viewer.parse_log(self.log, self.golden)
        result = viewer.compare(received, self.golden)
        self.assertTrue(result['window_exact'])
        self.assertEqual(result['worst_logit_ulp'], 0)
        self.assertTrue(result['agrees_with_golden'])
        self.assertEqual(received['launches'], self.golden['launches'])
        self.assertEqual(received['barriers'], self.golden['barriers'])

    def test_bad_logs_are_rejected(self):
        first = re.search(r'\[TFWIN\] 100 [0-9a-f]{4}\n', self.log).group(0)
        cases = {
            'incomplete': self.log.replace(first, ''),
            'duplicate': self.log + '[TFWIN] 100 0000\n',
            'case': self.log.replace(f'case={self.golden["case_id"]}',
                                     'case=deadbeefdeadbeef'),
            'weights': self.log.replace(
                f'weights={self.golden["weights_id"]}', 'weights=0123456789ab'),
            'failed': self.log.replace('[TFORMER] PASSED', '[TFORMER] FAILED'),
            'repeated header': self.log + self.log,
        }
        for name, text in cases.items():
            with self.subTest(case=name):
                with self.assertRaises(ValueError):
                    viewer.parse_log(text, self.golden)

    def test_one_ulp_is_reported_not_hidden(self):
        """The RTL run differed from the golden by 1 ULP; that must show."""
        golden_bits = int(self.golden['logits'][3])
        nudged = self.log.replace(f'[TFLOG] 3 {golden_bits:04x}',
                                  f'[TFLOG] 3 {golden_bits + 1:04x}')
        self.assertNotEqual(nudged, self.log, 'substitution did not apply')
        result = viewer.compare(viewer.parse_log(nudged, self.golden),
                                self.golden)
        self.assertEqual(result['worst_logit_ulp'], 1)
        self.assertEqual(result['logit_ulp'][3], 1)
        # A ULP on the smallest logit must not move the decision.
        self.assertTrue(result['agrees_with_golden'])
        self.assertGreater(result['margin'], 1.0)

    def test_ordered_key_is_monotonic_across_zero(self):
        """argmax on binary16 bits is only correct if this ordering holds."""
        bits = np.arange(0, 0x7c00, 7, dtype=np.uint16)
        both = np.concatenate([bits, (bits | 0x8000).astype(np.uint16)])
        values = both.view(np.float16).astype(np.float64)
        keys = viewer.ordered(both)
        order = np.argsort(keys, kind='stable')
        self.assertTrue(np.all(np.diff(values[order]) >= 0))


class TestHeaderPairing(unittest.TestCase):
    """A second export must not leave the first one comparing against the
    wrong answers. This is the bug a clean-clone `make demo` exposed: the
    vectors header was being overwritten by the chain export while the
    weights header still held the encoder model."""

    def test_every_weights_header_agrees_with_the_vectors_case(self):
        vectors = (APP / 'inc/tformer_vectors.h').read_text()
        case = viewer.header_define(vectors, 'TF_CASE_ID')
        found = sorted((APP / 'inc').glob('tformer_weights*.h'))
        self.assertTrue(found, 'no weights headers exported')
        for path in found:
            with self.subTest(header=path.name):
                golden = viewer.header_define(path.read_text(),
                                              'TF_GOLDEN_CASE_ID')
                self.assertEqual(golden, case,
                                 f'{path.name} was exported for a different '
                                 'case than tformer_vectors.h')

    def test_each_export_carries_its_own_logits(self):
        """The two models disagree; if the headers share a golden, one of
        them is wrong."""
        pair = [p for p in (APP / 'inc').glob('tformer_weights*.h')]
        if len(pair) < 2:
            self.skipTest('run: make model && make model-chain')
        goldens = {p.name: viewer.header_array(p.read_text(),
                                               'tf_logits_golden').tobytes()
                   for p in pair}
        self.assertEqual(len(set(goldens.values())), len(goldens),
                         f'two exports share one golden: {list(goldens)}')

    def test_loader_rejects_a_mismatched_pair(self):
        with tempfile.TemporaryDirectory() as folder:
            staged = Path(folder)
            (staged / 'tformer_weights.h').write_text(
                (APP / 'inc/tformer_weights.h').read_text().replace(
                    viewer.header_define(
                        (APP / 'inc/tformer_weights.h').read_text(),
                        'TF_GOLDEN_CASE_ID'),
                    'deadbeefdeadbeef'))
            (staged / 'tformer_vectors.h').write_text(
                (APP / 'inc/tformer_vectors.h').read_text())
            with self.assertRaises(ValueError):
                viewer.load_golden(staged)


class TestCases(unittest.TestCase):
    """`make cases`: an ihex written into the firmware's memory must make it
    run that case. load_image is emulated by patching a non-PIE host build of
    the firmware at the ihex addresses, then running it."""

    def setUp(self):
        import shutil
        if shutil.which('readelf') is None:
            self.skipTest('needs binutils readelf')

    def firmware(self, folder):
        import tformer_case as case
        binary = Path(folder) / f'{case.APP}.elf'
        result = build(binary, RUNTIME + [APP / 'main.c'], extra=['-no-pie'])
        self.assertEqual(result.returncode, 0, result.stderr)
        (Path(folder) / f'{case.APP}.readelf').write_text(subprocess.run(
            ['readelf', '-a', str(binary)], capture_output=True, text=True,
            check=True).stdout)
        return binary

    @staticmethod
    def load_image(binary, image, only=None):
        """Write the ihex into the ELF's loadable segments, as into RAM."""
        from intelhex import IntelHex
        import struct
        data = bytearray(binary.read_bytes())
        phoff, = struct.unpack_from('<Q', data, 0x20)
        size, count = struct.unpack_from('<HH', data, 0x36)
        segments = []
        for i in range(count):
            kind, _, offset, vaddr, _, filesz = struct.unpack_from(
                '<IIQQQQ', data, phoff + i * size)
            if kind == 1:
                segments.append((vaddr, filesz, offset))
        hexfile = IntelHex(str(image))
        for address in hexfile.addresses():
            if only and not only[0] <= address < only[1]:
                continue
            vaddr, _, offset = next(s for s in segments
                                    if s[0] <= address < s[0] + s[1])
            data[offset + address - vaddr] = hexfile[address]
        patched = binary.with_name(image.stem)
        patched.write_bytes(data)
        patched.chmod(0o755)
        return patched

    def test_each_case_runs_and_passes(self):
        import tformer_case as case
        blob = np.load(APP / 'results/radar_sequences.npz')
        with tempfile.TemporaryDirectory() as folder:
            binary = self.firmware(folder)
            with contextlib.redirect_stdout(io.StringIO()):
                case.main(['--bin', folder])
            for name in ('static', 'receding', 'crossing'):
                index = int(np.flatnonzero(
                    blob['test_y'] == rs.CLASSES.index(name))[0])
                run = subprocess.run([str(self.load_image(
                    binary, Path(folder) / f'{case.APP}-{name}.ihex'))],
                    capture_output=True, text=True)
                out = run.stdout
                self.assertIn('[TFORMER] PASSED', out, out[-600:])
                self.assertIn('errors=0 worst_ulp=0', out)
                self.assertIn(f'true={name}', out)
                window = [int(v, 16) for v in
                          re.findall(r'\[TFWIN\] \d+ ([0-9a-f]{4})', out)]
                features = blob['test_x'][index].astype(np.float16)
                expected = np.stack([features[:, :16], features[:, 16:]])
                self.assertEqual(window,
                                 expected.view(np.uint16).ravel().tolist())

    def test_window_without_its_goldens_fails(self):
        """The firmware reads the window from RAM: patching only tf_features
        must change the result, and the built-in goldens must reject it."""
        import tformer_case as case
        with tempfile.TemporaryDirectory() as folder:
            binary = self.firmware(folder)
            with contextlib.redirect_stdout(io.StringIO()):
                case.main(['--bin', folder, '--classes', 'crossing'])
            start = case.symbols((Path(folder) / f'{case.APP}.readelf')
                                 .read_text())['tf_features']
            run = subprocess.run([str(self.load_image(
                binary, Path(folder) / f'{case.APP}-crossing.ihex',
                only=(start, start + 768)))], capture_output=True, text=True)
            self.assertIn('[TFORMER] FAILED', run.stdout)
