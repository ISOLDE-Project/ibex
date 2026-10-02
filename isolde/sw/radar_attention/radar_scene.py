#!/usr/bin/env python3
"""Synthetic moving-target radar scenes for the radar_attention demo.

This generates what the existing receive beamformer in
``isolde/sw/radar_beamforming`` sees over a short observation window, and
reduces each frame to a 32-value feature vector using only operations that
Ibex can perform without scalar floating point (sign masks, unsigned 16-bit
compares and table lookups).

Scope and honesty notes
-----------------------
* The antenna array, steering convention, range-bin assignment, noise level
  and the FP16 accumulation model mirror
  ``isolde/sw/radar_beamforming/beamforming.py``.  ``tests/test_radar_scene.py``
  asserts that the shared constants still agree with that file.
* There is no transmitted waveform, ADC sampling, range FFT, Doppler
  processing, calibration, tracker or CFAR detector here.  Each frame is one
  synthetic post-range-processing snapshot, exactly as in the beamforming
  example.  The metre and second scales are assigned, not simulated.
* Target motion *is* physical: constant velocity in the ground plane, with
  range and bearing recomputed from Cartesian position every frame.  The
  angular rate therefore changes with range on its own; it is not scripted.
* No range law (1/r^k) is applied by default, matching the existing example,
  whose target amplitudes are independent of range bin.  ``--range-law``
  enables a two-way 1/r^4 taper for experiments.

Class labels come from the sampled initial radial/tangential velocity split,
before any noise is added, so labels cannot leak from the measurement.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np

# ---------------------------------------------------------------------------
# Array and scene geometry.  Mirrors radar_beamforming/beamforming.py.
# ---------------------------------------------------------------------------
N_BEAMS, N_ANT, N_BINS, BLOCK_M = 36, 16, 16, 12
ANGLES = np.linspace(-70.0, 70.0, N_BEAMS)      # degrees from broadside
RANGE_BIN_M = 25.0
RANGES = RANGE_BIN_M * (1 + np.arange(N_BINS))  # 25 m .. 400 m
NOISE_SIGMA = 0.02
RANGE_SPREAD_BINS = 0.48                        # target extent, as in the example

# ---------------------------------------------------------------------------
# Observation window.
# ---------------------------------------------------------------------------
N_FRAMES = 12                                   # == RedMulE ARRAY_HEIGHT*PIPE_REGS
DT = 0.25                                       # s between frames (decimated
                                                # track update; assigned, not
                                                # derived from a PRF)

CLASSES = ('static', 'approaching', 'receding', 'crossing')

# Classes are defined by what the *realised* track does over the window, not by
# the velocity that was sampled to produce it.  A constant-velocity target that
# crosses the beam also opens in range, so defining "crossing" by tangential
# speed alone makes it overlap "receding" and puts unlearnable noise in the
# labels.  Every track is accepted only if its realised range change (in bins,
# signed, first to last frame) and its realised bearing change (degrees,
# absolute) fall inside the band below.  The bands do not overlap.
CLASS_SPEC = {
    'static':      dict(delta_range_bins=(-0.35, 0.35), delta_angle=(0.0, 4.0)),
    'approaching': dict(delta_range_bins=(-6.0, -1.2),  delta_angle=(0.0, 8.0)),
    'receding':    dict(delta_range_bins=(1.2, 6.0),    delta_angle=(0.0, 8.0)),
    'crossing':    dict(delta_range_bins=(-0.8, 0.8),   delta_angle=(12.0, 60.0)),
}

# Sampling hints; the acceptance test above is what actually defines a class.
CLASS_SAMPLING = {
    'static':      dict(radial=(0.0, 2.0),  tangential=(0.0, 2.0),  radial_sign=0),
    'approaching': dict(radial=(10.0, 40.0), tangential=(0.0, 6.0), radial_sign=-1),
    'receding':    dict(radial=(10.0, 40.0), tangential=(0.0, 6.0), radial_sign=+1),
}
# "crossing" is generated from its closest point of approach instead, so the
# range is symmetric about the middle of the window and nets out near zero.
CPA_RANGE_M = (60.0, 250.0)
CPA_SPEED_M_S = (20.0, 60.0)

# Keep the whole track inside the scanned sector and away from the first and
# last range bins, so nothing is clipped by the edge of the observation space.
R_MIN_M, R_MAX_M = 1.6 * RANGE_BIN_M, 15.4 * RANGE_BIN_M
THETA_LIMIT_DEG = 58.0

# ---------------------------------------------------------------------------
# Feature extraction.  36 beams collapse into 16 angle groups of 2 or 3 beams;
# the pattern repeats every 9 beams (3,2,2,2) and covers 0..35 exactly.
# ---------------------------------------------------------------------------
_GROUP_SIZES = np.array([3, 2, 2, 2] * 4)
ANGLE_GROUP_EDGES = np.concatenate([[0], np.cumsum(_GROUP_SIZES)])
N_ANGLE_FEATURES = len(_GROUP_SIZES)            # 16
N_FEATURES = N_ANGLE_FEATURES + N_BINS          # 32

# Dynamic range kept after per-sequence normalisation, as a Q8.8 log2 value.
# -2048 is -8.0 in log2, i.e. -48.16 dB.  The power of two is deliberate: the
# normalised feature is (clamped + 2048) * 2^-11, and every integer in
# [0, 2048] is exactly representable in binary16, so the firmware can build the
# feature's bit pattern with a count-leading-zeros and a shift.  A floor that
# is not a power of two would need a real division and therefore an FPU.
LOG_FLOOR_Q = -2048
LOG_SCALE_SHIFT = 11
DB_PER_LOG2 = 6.020599913279624
LOG_FLOOR_DB = LOG_FLOOR_Q / 256.0 * DB_PER_LOG2


def steering_matrix():
    """A[beam, antenna] = conj(a(theta_beam)) / N, as in beamforming.py."""
    antenna = np.arange(N_ANT)
    return np.exp(-1j * np.pi * np.sin(np.deg2rad(ANGLES))[:, None]
                  * antenna[None, :]) / N_ANT


# ---------------------------------------------------------------------------
# Kinematics
# ---------------------------------------------------------------------------
def _propagate(p0, vel, t_offset=0.0):
    """Constant velocity in the ground plane; returns range and bearing.

    Broadside is +y.  theta = atan2(x, y), so positive theta is to the right,
    matching the beamforming example's angle convention.
    """
    t = DT * np.arange(N_FRAMES) - t_offset
    p = p0[None, :] + vel[None, :] * t[:, None]
    return (np.hypot(p[:, 0], p[:, 1]),
            np.degrees(np.arctan2(p[:, 0], p[:, 1])))


def track_statistics(range_m, angle_deg):
    """The two quantities the class definition is written in terms of."""
    return dict(delta_range_bins=(range_m[-1] - range_m[0]) / RANGE_BIN_M,
                delta_angle=abs(angle_deg[-1] - angle_deg[0]))


def _in_class(range_m, angle_deg, name):
    spec = CLASS_SPEC[name]
    stats = track_statistics(range_m, angle_deg)
    lo, hi = spec['delta_range_bins']
    if not lo <= stats['delta_range_bins'] <= hi:
        return False
    lo, hi = spec['delta_angle']
    if not lo <= stats['delta_angle'] <= hi:
        return False
    return (range_m.min() >= R_MIN_M and range_m.max() <= R_MAX_M
            and np.abs(angle_deg).max() <= THETA_LIMIT_DEG)


def sample_track(rng, class_index):
    """Constant-velocity ground-plane track satisfying CLASS_SPEC[name]."""
    name = CLASSES[class_index]
    for _ in range(4000):
        if name == 'crossing':
            # Parameterised by the closest point of approach, with the CPA
            # placed near the middle of the window.  The range profile is then
            # symmetric and nets out, while the bearing sweeps through.
            r_cpa = rng.uniform(*CPA_RANGE_M)
            theta_cpa = np.deg2rad(rng.uniform(-30.0, 30.0))
            speed = rng.uniform(*CPA_SPEED_M_S) * rng.choice((-1.0, 1.0))
            u_r = np.array([np.sin(theta_cpa), np.cos(theta_cpa)])
            u_t = np.array([np.cos(theta_cpa), -np.sin(theta_cpa)])
            p_cpa, vel = r_cpa * u_r, speed * u_t
            t_cpa = DT * (N_FRAMES - 1) / 2.0 + rng.uniform(-DT, DT)
            r, theta = _propagate(p_cpa, vel, t_offset=t_cpa)
            v_r, v_t = 0.0, speed
        else:
            spec = CLASS_SAMPLING[name]
            r0 = rng.uniform(R_MIN_M + 40.0, R_MAX_M - 40.0)
            theta0 = np.deg2rad(rng.uniform(-THETA_LIMIT_DEG + 6.0,
                                            THETA_LIMIT_DEG - 6.0))
            v_r = rng.uniform(*spec['radial']) * (spec['radial_sign']
                                                  or rng.choice((-1.0, 1.0)))
            v_t = rng.uniform(*spec['tangential']) * rng.choice((-1.0, 1.0))
            u_r = np.array([np.sin(theta0), np.cos(theta0)])
            u_t = np.array([np.cos(theta0), -np.sin(theta0)])
            r, theta = _propagate(r0 * u_r, v_r * u_r + v_t * u_t)

        if _in_class(r, theta, name):
            return dict(range_m=r, angle_deg=theta, v_radial=v_r,
                        v_tangential=v_t, r0=r[0], theta0=theta[0],
                        **track_statistics(r, theta))
    raise RuntimeError(f'could not place a {name} track meeting CLASS_SPEC')


def snapshots(rng, track, amplitude, interferers, range_law):
    """Per-frame antenna snapshot B[frame, antenna, bin], complex128."""
    antenna = np.arange(N_ANT)
    bins = np.arange(N_BINS)
    b = np.zeros((N_FRAMES, N_ANT, N_BINS), dtype=np.complex128)

    # Swerling-2 style: independent power fluctuation frame to frame.
    fluctuation = np.sqrt(rng.exponential(1.0, size=N_FRAMES))
    phase = rng.uniform(0.0, 2 * np.pi, size=N_FRAMES)
    bin_phase = rng.uniform(-0.2, 0.2)

    for f in range(N_FRAMES):
        r_bin = track['range_m'][f] / RANGE_BIN_M - 1.0    # 0-based, continuous
        steer = np.exp(1j * np.pi * antenna
                       * np.sin(np.deg2rad(track['angle_deg'][f])))
        profile = np.exp(-0.5 * ((bins - r_bin) / RANGE_SPREAD_BINS) ** 2)
        amp = amplitude * fluctuation[f]
        if range_law:
            amp *= (RANGES[7] / track['range_m'][f]) ** 2
        echo = amp * profile * np.exp(1j * (phase[f] + bin_phase * bins))
        b[f] += steer[:, None] * echo[None, :]

    for it in interferers:
        steer = np.exp(1j * np.pi * antenna * np.sin(np.deg2rad(it['angle_deg'])))
        profile = np.exp(-0.5 * ((bins - it['range_bin']) / RANGE_SPREAD_BINS) ** 2)
        echo = it['amplitude'] * profile * np.exp(1j * (it['phase'] + 0.13 * bins))
        b += (steer[:, None] * echo[None, :])[None, :, :]

    b += NOISE_SIGMA / np.sqrt(2) * (rng.standard_normal(b.shape)
                                     + 1j * rng.standard_normal(b.shape))
    return b


def sample_interferers(rng, track):
    """Weaker static returns, so the moving target stays the dominant one."""
    out = []
    for _ in range(rng.integers(0, 3)):
        for _attempt in range(50):
            angle = rng.uniform(-THETA_LIMIT_DEG, THETA_LIMIT_DEG)
            r_bin = rng.uniform(1.0, 14.0)
            separated = (np.abs(track['angle_deg'] - angle).min() > 9.0
                         or np.abs(track['range_m'] / RANGE_BIN_M - 1.0
                                   - r_bin).min() > 2.0)
            if separated:
                out.append(dict(angle_deg=angle, range_bin=r_bin,
                                amplitude=rng.uniform(0.12, 0.35),
                                phase=rng.uniform(0.0, 2 * np.pi)))
                break
    return out


# ---------------------------------------------------------------------------
# FP16 GEMM model, batched.  Same arithmetic as beamforming.py:real_accumulate
# (float32 multiply-add, rounded to FP16 after every reduction step).
# ---------------------------------------------------------------------------
def real_accumulate_batched(x, w, y=None):
    """x[M, K] fixed, w[B, K, N] batched -> out[B, M, N], FP16 per k-step."""
    x = np.asarray(x, dtype=np.float16)
    w = np.asarray(w, dtype=np.float16)
    batch = w.shape[0]
    out = (np.zeros((batch, x.shape[0], w.shape[2]), dtype=np.float16)
           if y is None else np.array(y, dtype=np.float16, copy=True))
    for k in range(x.shape[1]):
        out = (x[None, :, k, None].astype(np.float32)
               * w[:, None, k, :].astype(np.float32)
               + out.astype(np.float32)).astype(np.float16)
    return out


def beamform_fp16(ar, ai, br, bi):
    """Split-complex beamforming, identical decomposition to the radar demo."""
    cr = real_accumulate_batched(ai, -bi, real_accumulate_batched(ar, br))
    ci = real_accumulate_batched(ai, br, real_accumulate_batched(ar, bi))
    return cr, ci


# ---------------------------------------------------------------------------
# Feature extraction: everything below is expressible on Ibex with sign masks,
# unsigned 16-bit compares and one lookup table.  No scalar FP is required.
# ---------------------------------------------------------------------------
LOG2_LUT_SHIFT = 6
LOG2_LUT_SIZE = 512          # covers every non-negative binary16, 1 KiB as int16


def build_log2_lut():
    """512-entry table: bits[14:6] of a non-negative binary16 -> Q8.8 log2.

    The index keeps the 5-bit exponent and the 4 most significant mantissa
    bits; each entry therefore stands for a 64-code interval.  Storing the
    log2 of that interval's geometric mean is the minimax choice and bounds
    the error at +/-0.26 dB.  Zero, subnormals below the first code, infinity
    and NaN all saturate low, which is what the noise floor clamp wants.
    """
    index = np.arange(LOG2_LUT_SIZE, dtype=np.uint32)
    lo_bits = (index << LOG2_LUT_SHIFT).astype(np.uint16)
    hi_bits = (lo_bits.astype(np.uint32)
               + ((1 << LOG2_LUT_SHIFT) - 1)).astype(np.uint16)
    lo = lo_bits.view(np.float16).astype(np.float64)
    hi = hi_bits.view(np.float16).astype(np.float64)
    finite = np.isfinite(lo) & np.isfinite(hi) & (lo > 0)
    log2 = np.full(LOG2_LUT_SIZE, -32.0)
    log2[finite] = 0.5 * (np.log2(lo[finite]) + np.log2(hi[finite]))
    return np.round(log2 * 256.0).astype(np.int32)


LOG2_LUT = build_log2_lut()


def magnitude_proxy(cr, ci):
    """max(|Cr|, |Ci|): a sign-bit mask plus an unsigned compare on Ibex.

    For non-negative binary16 the unsigned integer order equals the float
    order, so the compare needs no floating-point unit.  This under-reads a
    true magnitude by at most 3 dB (when |Cr| == |Ci|) and never over-reads.
    """
    return np.maximum(np.abs(cr), np.abs(ci)).astype(np.float16)


def marginal_profiles(mag):
    """mag[..., beam, bin] -> (angle profile [..., 16], range profile [..., 16]).

    Max-projection of the range-angle map onto each axis.  Both projections
    are unsigned 16-bit maxima on device.
    """
    per_beam = mag.max(axis=-1)                     # [..., 36]
    angle = np.stack([per_beam[..., ANGLE_GROUP_EDGES[g]:ANGLE_GROUP_EDGES[g + 1]]
                      .max(axis=-1) for g in range(N_ANGLE_FEATURES)], axis=-1)
    rng_profile = mag.max(axis=-2)                  # [..., 16]
    return angle.astype(np.float16), rng_profile.astype(np.float16)


def log_normalise(profiles):
    """profiles[frames, 32] FP16 -> [frames, 32] float16 in [0, 1].

    Table lookup to Q8.8 log2, integer subtraction of the per-sequence peak,
    integer clamp at the noise floor, then an exact power-of-two rescale.
    Every step is what the firmware does, in the order it does it.
    """
    bits = np.ascontiguousarray(profiles, dtype=np.float16).view(np.uint16)
    log2q = LOG2_LUT[(bits >> LOG2_LUT_SHIFT).astype(np.int32)]   # Q8.8 log2
    peak = log2q.max()
    counts = np.clip(log2q - peak, LOG_FLOOR_Q, 0) - LOG_FLOOR_Q  # 0 .. 2048
    # Exact in binary16: the integer has at most 12 significant bits and the
    # scale is a power of two well inside the normal exponent range.
    return np.ldexp(counts.astype(np.float32),
                    -LOG_SCALE_SHIFT).astype(np.float16)


def features_from_maps(cr, ci):
    """cr, ci [frames, 36, 16] -> [frames, 32] FP16 features in [0, 1]."""
    mag = magnitude_proxy(cr, ci)
    angle, rng_profile = marginal_profiles(mag)
    return log_normalise(np.concatenate([angle, rng_profile], axis=-1))


# ---------------------------------------------------------------------------
# Dataset assembly
# ---------------------------------------------------------------------------
def make_sequence(rng, class_index, range_law=False):
    track = sample_track(rng, class_index)
    interferers = sample_interferers(rng, track)
    amplitude = rng.uniform(0.5, 1.2)
    b = snapshots(rng, track, amplitude, interferers, range_law)
    a = steering_matrix()
    ar, ai = (np.ascontiguousarray(a.real, dtype=np.float16),
              np.ascontiguousarray(a.imag, dtype=np.float16))
    br, bi = (np.ascontiguousarray(b.real, dtype=np.float16),
              np.ascontiguousarray(b.imag, dtype=np.float16))
    cr, ci = beamform_fp16(ar, ai, br, bi)
    return dict(features=features_from_maps(cr, ci), cr=cr, ci=ci,
                snapshots=b, track=track, amplitude=amplitude,
                n_interferers=len(interferers))


def build_split(n, seed, range_law=False, keep_maps=0):
    rng = np.random.default_rng(seed)
    labels = np.tile(np.arange(len(CLASSES)), n // len(CLASSES) + 1)[:n]
    rng.shuffle(labels)
    x = np.zeros((n, N_FRAMES, N_FEATURES), dtype=np.float16)
    track_keys = ('v_radial', 'v_tangential', 'r0', 'theta0',
                  'delta_range_bins', 'delta_angle')
    meta = {k: np.zeros(n) for k in track_keys + ('amplitude', 'n_interferers')}
    tracks_r = np.zeros((n, N_FRAMES))
    tracks_a = np.zeros((n, N_FRAMES))
    maps = []
    for i in range(n):
        seq = make_sequence(rng, int(labels[i]), range_law)
        x[i] = seq['features']
        tracks_r[i] = seq['track']['range_m']
        tracks_a[i] = seq['track']['angle_deg']
        for k in track_keys:
            meta[k][i] = seq['track'][k]
        meta['amplitude'][i] = seq['amplitude']
        meta['n_interferers'][i] = seq['n_interferers']
        if len(maps) < keep_maps:
            maps.append(dict(label=int(labels[i]), cr=seq['cr'], ci=seq['ci'],
                             range_m=seq['track']['range_m'],
                             angle_deg=seq['track']['angle_deg']))
    return dict(x=x, y=labels.astype(np.int64), range_m=tracks_r,
                angle_deg=tracks_a, maps=maps, **meta)


def dataset_id(splits):
    digest = hashlib.sha256()
    for name in sorted(splits):
        digest.update(name.encode())
        digest.update(splits[name]['x'].astype('<f2').tobytes())
        digest.update(splits[name]['y'].astype('<i8').tobytes())
    return digest.hexdigest()[:16]


def emit_feature_header(path):
    """The feature front end's constants, so C and Python cannot disagree."""
    lines = [
        '/* Generated by radar_scene.py. Feature front end constants. */',
        '#ifndef TFORMER_FEATURES_CONST_H', '#define TFORMER_FEATURES_CONST_H',
        '#include <stdint.h>', '',
        f'#define TF_BEAMS {N_BEAMS}u',
        f'#define TF_RANGE_BINS {N_BINS}u',
        f'#define TF_ANGLE_GROUPS {N_ANGLE_FEATURES}u',
        f'#define TF_LOG2_LUT_SHIFT {LOG2_LUT_SHIFT}u',
        f'#define TF_LOG2_LUT_SIZE {LOG2_LUT_SIZE}u',
        f'#define TF_LOG_FLOOR_Q ({LOG_FLOOR_Q})',
        f'#define TF_LOG_SCALE_SHIFT {LOG_SCALE_SHIFT}u', '',
        '/* Beam index at which each of the 16 angle groups starts; the last',
        ' * entry is TF_BEAMS so the firmware can walk edges pairwise. */',
        f'static const uint8_t tf_angle_group_edge[{len(ANGLE_GROUP_EDGES)}] = {{',
        '  ' + ', '.join(str(int(e)) for e in ANGLE_GROUP_EDGES), '};', '',
        '/* Q8.8 log2 of each interval geometric mean; index is bits >> 6. */',
        f'static const int16_t tf_log2_lut[TF_LOG2_LUT_SIZE] = {{']
    values = LOG2_LUT.astype(np.int32)
    lines += ['  ' + ', '.join(f'{int(v)}' for v in values[i:i + 12]) + ','
              for i in range(0, len(values), 12)]
    lines += ['};', '', '#endif', '']
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text('\n'.join(lines))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--header-dir', type=Path, default=None,
                        help='also emit inc/tformer_features_const.h')
    parser.add_argument('--out-dir', type=Path, default=Path('results'))
    parser.add_argument('--train', type=int, default=3000)
    parser.add_argument('--val', type=int, default=600)
    parser.add_argument('--test', type=int, default=600)
    parser.add_argument('--seed', type=int, default=7)
    parser.add_argument('--range-law', action='store_true',
                        help='apply a two-way 1/r^4 amplitude taper')
    parser.add_argument('--keep-maps', type=int, default=8,
                        help='range-angle maps retained from the test split')
    args = parser.parse_args()

    splits = {}
    for offset, (name, count) in enumerate((('train', args.train),
                                            ('val', args.val),
                                            ('test', args.test))):
        splits[name] = build_split(count, args.seed + 1000 * offset,
                                   args.range_law,
                                   args.keep_maps if name == 'test' else 0)
        print(f'{name:>5}: {count} sequences')

    args.out_dir.mkdir(parents=True, exist_ok=True)
    payload = {}
    for name, split in splits.items():
        for key in ('x', 'y', 'range_m', 'angle_deg', 'v_radial',
                    'v_tangential', 'r0', 'theta0', 'delta_range_bins',
                    'delta_angle', 'amplitude', 'n_interferers'):
            payload[f'{name}_{key}'] = split[key]
    for i, m in enumerate(splits['test']['maps']):
        payload[f'map{i}_cr'] = m['cr']
        payload[f'map{i}_ci'] = m['ci']
        payload[f'map{i}_label'] = np.int64(m['label'])
        payload[f'map{i}_range_m'] = m['range_m']
        payload[f'map{i}_angle_deg'] = m['angle_deg']
    payload['n_maps'] = np.int64(len(splits['test']['maps']))
    np.savez_compressed(args.out_dir / 'radar_sequences.npz', **payload)

    summary = dict(
        case_id=dataset_id(splits), seed=args.seed, range_law=args.range_law,
        frames=N_FRAMES, dt_s=DT, features=N_FEATURES, classes=list(CLASSES),
        beams=N_BEAMS, antennas=N_ANT, range_bins=N_BINS,
        range_bin_m=RANGE_BIN_M, noise_sigma=NOISE_SIGMA,
        log_floor_db=LOG_FLOOR_DB,
        class_spec={k: {kk: list(vv) for kk, vv in v.items()}
                    for k, v in CLASS_SPEC.items()},
        log_floor_q=LOG_FLOOR_Q, log_scale_shift=LOG_SCALE_SHIFT,
        counts={name: {CLASSES[c]: int((s['y'] == c).sum())
                       for c in range(len(CLASSES))}
                for name, s in splits.items()},
        realised={CLASSES[c]: dict(
            delta_range_bins=[float(splits['train']['delta_range_bins']
                                    [splits['train']['y'] == c].min()),
                              float(splits['train']['delta_range_bins']
                                    [splits['train']['y'] == c].max())],
            delta_angle_deg=[float(splits['train']['delta_angle']
                                   [splits['train']['y'] == c].min()),
                             float(splits['train']['delta_angle']
                                   [splits['train']['y'] == c].max())])
            for c in range(len(CLASSES))},
    )
    (args.out_dir / 'dataset_summary.json').write_text(
        json.dumps(summary, indent=2) + '\n')
    if args.header_dir is not None:
        emit_feature_header(args.header_dir / 'tformer_features_const.h')
        print('wrote', args.header_dir / 'tformer_features_const.h')
    print('case_id', summary['case_id'])
    print('wrote', args.out_dir / 'radar_sequences.npz')


if __name__ == '__main__':
    main()
