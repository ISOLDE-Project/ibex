#!/usr/bin/env python3
"""Host tests for the radar_attention scene generator.

These check agreement with the existing beamforming example, the physical
consistency of the generated tracks, and that the feature front end really is
expressible with integer operations only.  They do not simulate RTL.
"""
from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
PKG = HERE.parent
sys.path.insert(0, str(PKG))

import radar_scene as rs  # noqa: E402


def _load_beamforming():
    path = PKG.parent / 'radar_beamforming' / 'beamforming.py'
    if not path.exists():
        return None
    spec = importlib.util.spec_from_file_location('beamforming', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


BF = _load_beamforming()


class TestSharedConstants(unittest.TestCase):
    """radar_scene re-declares the geometry; it must not drift from the source."""

    @unittest.skipIf(BF is None, 'radar_beamforming/beamforming.py not present')
    def test_geometry_matches_beamforming_example(self):
        self.assertEqual((rs.N_BEAMS, rs.N_ANT, rs.N_BINS, rs.BLOCK_M),
                         (BF.M, BF.N, BF.K, BF.BLOCK_M))
        np.testing.assert_allclose(rs.ANGLES, BF.ANGLES)
        np.testing.assert_allclose(rs.RANGES, BF.RANGES)

    @unittest.skipIf(BF is None, 'radar_beamforming/beamforming.py not present')
    def test_steering_matches_beamforming_example(self):
        a, _ = BF.make_scene(seed=7)
        np.testing.assert_allclose(rs.steering_matrix(), a, rtol=0, atol=0)

    @unittest.skipIf(BF is None, 'radar_beamforming/beamforming.py not present')
    def test_batched_accumulate_matches_scalar_reference(self):
        rng = np.random.default_rng(0)
        x = rng.standard_normal((rs.N_BEAMS, rs.N_ANT)).astype(np.float16)
        w = rng.standard_normal((5, rs.N_ANT, rs.N_BINS)).astype(np.float16)
        batched = rs.real_accumulate_batched(x, w)
        for i in range(w.shape[0]):
            np.testing.assert_array_equal(
                batched[i].view(np.uint16),
                BF.real_accumulate(x, w[i]).view(np.uint16),
                err_msg=f'batch element {i} differs from the scalar reference')


class TestAngleGroups(unittest.TestCase):
    def test_groups_tile_the_beam_axis_exactly(self):
        edges = rs.ANGLE_GROUP_EDGES
        self.assertEqual(edges[0], 0)
        self.assertEqual(edges[-1], rs.N_BEAMS)
        self.assertEqual(len(edges) - 1, rs.N_ANGLE_FEATURES)
        sizes = np.diff(edges)
        self.assertTrue(set(np.unique(sizes)).issubset({2, 3}))
        self.assertEqual(rs.N_FEATURES, rs.N_ANGLE_FEATURES + rs.N_BINS)
        self.assertEqual(rs.N_FEATURES % 16, 0,
                         'feature width must be a whole number of 16-wide tiles')


class TestKinematics(unittest.TestCase):
    def test_tracks_stay_inside_the_observation_space(self):
        rng = np.random.default_rng(3)
        for class_index in range(len(rs.CLASSES)):
            for _ in range(40):
                track = rs.sample_track(rng, class_index)
                self.assertGreaterEqual(track['range_m'].min(), rs.R_MIN_M)
                self.assertLessEqual(track['range_m'].max(), rs.R_MAX_M)
                self.assertLessEqual(np.abs(track['angle_deg']).max(),
                                     rs.THETA_LIMIT_DEG)

    def test_motion_is_constant_velocity_in_cartesian(self):
        rng = np.random.default_rng(11)
        track = rs.sample_track(rng, rs.CLASSES.index('crossing'))
        r, theta = track['range_m'], np.deg2rad(track['angle_deg'])
        xy = np.stack([r * np.sin(theta), r * np.cos(theta)], axis=-1)
        step = np.diff(xy, axis=0)
        np.testing.assert_allclose(step, np.broadcast_to(step[0], step.shape),
                                   rtol=1e-9, atol=1e-7)

    def test_every_track_satisfies_its_own_class_spec(self):
        rng = np.random.default_rng(5)
        for class_index, name in enumerate(rs.CLASSES):
            spec = rs.CLASS_SPEC[name]
            for _ in range(40):
                track = rs.sample_track(rng, class_index)
                stats = rs.track_statistics(track['range_m'],
                                            track['angle_deg'])
                lo, hi = spec['delta_range_bins']
                self.assertTrue(lo <= stats['delta_range_bins'] <= hi,
                                f'{name}: dr {stats["delta_range_bins"]:.2f}')
                lo, hi = spec['delta_angle']
                self.assertTrue(lo <= stats['delta_angle'] <= hi,
                                f'{name}: dtheta {stats["delta_angle"]:.2f}')

    def test_class_bands_do_not_overlap(self):
        """No track can satisfy two class definitions at once."""
        def overlaps(a, b, key):
            (alo, ahi), (blo, bhi) = a[key], b[key]
            return max(alo, blo) <= min(ahi, bhi)

        names = list(rs.CLASS_SPEC)
        for i, a in enumerate(names):
            for b in names[i + 1:]:
                sa, sb = rs.CLASS_SPEC[a], rs.CLASS_SPEC[b]
                disjoint = (not overlaps(sa, sb, 'delta_range_bins')
                            or not overlaps(sa, sb, 'delta_angle'))
                self.assertTrue(disjoint, f'{a} and {b} overlap')

    def test_approaching_and_receding_move_monotonically(self):
        rng = np.random.default_rng(23)
        for name, expected in (('approaching', -1), ('receding', +1)):
            for _ in range(25):
                track = rs.sample_track(rng, rs.CLASSES.index(name))
                delta = np.diff(track['range_m'])
                self.assertTrue(np.all(np.sign(delta) == expected))

    def test_crossing_turns_around_inside_the_window(self):
        """Closest approach must fall inside the observed frames, otherwise a
        crossing target is just a slow receding one."""
        rng = np.random.default_rng(29)
        for _ in range(30):
            track = rs.sample_track(rng, rs.CLASSES.index('crossing'))
            closest = int(np.argmin(track['range_m']))
            self.assertIn(closest, range(1, rs.N_FRAMES - 1),
                          'CPA landed on the window edge')


class TestFeatureFrontEndIsIntegerOnly(unittest.TestCase):
    """Each stage must be reproducible with uint16 compares and one table."""

    def test_magnitude_proxy_is_a_sign_mask_and_unsigned_max(self):
        rng = np.random.default_rng(1)
        cr = rng.standard_normal((4, 36, 16)).astype(np.float16)
        ci = rng.standard_normal((4, 36, 16)).astype(np.float16)
        reference = rs.magnitude_proxy(cr, ci)

        # Integer model: clear the sign bit, then take the unsigned maximum.
        a = cr.view(np.uint16) & np.uint16(0x7FFF)
        b = ci.view(np.uint16) & np.uint16(0x7FFF)
        integer = np.maximum(a, b).view(np.float16)
        np.testing.assert_array_equal(integer.view(np.uint16),
                                      reference.view(np.uint16))

    def test_magnitude_proxy_never_over_reads_and_loses_at_most_3dB(self):
        rng = np.random.default_rng(2)
        cr = rng.standard_normal(20000).astype(np.float16)
        ci = rng.standard_normal(20000).astype(np.float16)
        proxy = rs.magnitude_proxy(cr, ci).astype(np.float64)
        true = np.hypot(cr.astype(np.float64), ci.astype(np.float64))
        ratio = proxy[true > 1e-3] / true[true > 1e-3]
        self.assertLessEqual(ratio.max(), 1.0 + 1e-6)
        self.assertGreaterEqual(ratio.min(), 1.0 / np.sqrt(2) - 1e-3)

    def test_marginal_profiles_are_maxima_of_the_map(self):
        rng = np.random.default_rng(4)
        mag = np.abs(rng.standard_normal((3, 36, 16))).astype(np.float16)
        angle, rng_profile = rs.marginal_profiles(mag)
        np.testing.assert_array_equal(rng_profile.view(np.uint16),
                                      mag.max(axis=-2).view(np.uint16))
        for g in range(rs.N_ANGLE_FEATURES):
            lo, hi = rs.ANGLE_GROUP_EDGES[g], rs.ANGLE_GROUP_EDGES[g + 1]
            np.testing.assert_array_equal(
                angle[..., g].view(np.uint16),
                mag[..., lo:hi, :].max(axis=(-2, -1)).view(np.uint16))

    def test_log_lut_holds_the_minimax_error_bound(self):
        """Every normal non-negative binary16, not just a sample of them."""
        bits = np.arange(0x0400, 0x7C00, dtype=np.uint16)     # normals only
        values = bits.view(np.float16).astype(np.float64)
        from_lut = rs.LOG2_LUT[(bits >> rs.LOG2_LUT_SHIFT).astype(np.int32)] / 256.0
        db_error = np.abs(from_lut - np.log2(values)) * 6.020599913279624
        self.assertLess(db_error.max(), 0.27, f'max {db_error.max():.3f} dB')

    def test_log_lut_is_one_kibibyte_and_covers_every_index(self):
        self.assertEqual(rs.LOG2_LUT_SIZE, 512)
        self.assertEqual(rs.LOG2_LUT.shape, (512,))
        self.assertLess(np.uint16(0x7FFF) >> rs.LOG2_LUT_SHIFT, rs.LOG2_LUT_SIZE)
        self.assertTrue(np.all(np.abs(rs.LOG2_LUT) < 2 ** 15),
                        'entries must fit an int16 Q8.8 table')

    def test_log_lut_saturates_on_zero_and_on_non_finite(self):
        for bits in (0x0000, 0x7C00, 0x7FFF):                 # zero, inf, NaN
            index = bits >> rs.LOG2_LUT_SHIFT
            self.assertLessEqual(rs.LOG2_LUT[index], -32 * 256 + 1)

    def test_features_are_bounded_and_peak_normalised(self):
        rng = np.random.default_rng(6)
        seq = rs.make_sequence(rng, rs.CLASSES.index('approaching'))
        x = seq['features'].astype(np.float64)
        self.assertGreaterEqual(x.min(), 0.0)
        self.assertLessEqual(x.max(), 1.0)
        self.assertAlmostEqual(x.max(), 1.0, places=3,
                               msg='the sequence peak must normalise to 1.0')


class TestDataset(unittest.TestCase):
    def test_split_is_balanced_and_shaped(self):
        split = rs.build_split(40, seed=21)
        self.assertEqual(split['x'].shape, (40, rs.N_FRAMES, rs.N_FEATURES))
        self.assertEqual(split['x'].dtype, np.float16)
        counts = np.bincount(split['y'], minlength=len(rs.CLASSES))
        self.assertTrue(np.all(counts == 10), f'unbalanced: {counts}')

    def test_generation_is_deterministic_for_a_seed(self):
        a = rs.build_split(12, seed=99)
        b = rs.build_split(12, seed=99)
        np.testing.assert_array_equal(a['x'].view(np.uint16),
                                      b['x'].view(np.uint16))
        np.testing.assert_array_equal(a['y'], b['y'])

    def test_amplitude_alone_does_not_reveal_the_class(self):
        """Per-sequence peak normalisation must remove absolute RCS."""
        split = rs.build_split(120, seed=33)
        peak = split['x'].astype(np.float64).max(axis=(1, 2))
        np.testing.assert_allclose(peak, 1.0, atol=1e-3)


if __name__ == '__main__':
    unittest.main(verbosity=2)
