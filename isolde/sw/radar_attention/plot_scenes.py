#!/usr/bin/env python3
"""Figures for the radar_attention synthetic dataset.

Writes four PNGs into --out-dir:

  scene_maps.png        the range-angle map the beamformer produces, one row
                        per class, across the observation window
  features.png          the 12 x 32 feature window the encoder actually sees
  class_separation.png  realised range/bearing change against CLASS_SPEC
  tracks.png            the underlying constant-velocity tracks

Colour follows the validated reference palette: a single-hue blue sequential
ramp for magnitude, and four categorical hues that clear the all-pairs CVD and
normal-vision floors.  Every panel is direct-labelled, so identity is never
carried by colour alone.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import matplotlib
import numpy as np

matplotlib.use('Agg')
import matplotlib.pyplot as plt                                    # noqa: E402
from matplotlib.colors import LinearSegmentedColormap              # noqa: E402
from matplotlib.patches import Rectangle                           # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parent))
import radar_scene as rs                                           # noqa: E402

SURFACE = '#fcfcfb'
INK = '#0b0b0b'
INK_SECONDARY = '#52514e'
INK_MUTED = '#8a8880'
GRID = '#e4e3df'

# Categorical slots 1, 2, 3 and 7 of the reference palette.  Validated
# all-pairs in light mode: worst CVD dE 9.2, worst normal-vision dE 16.3.
CLASS_COLOURS = {'static': '#2a78d6', 'approaching': '#eb6834',
                 'receding': '#1baf7a', 'crossing': '#4a3aa7'}
CLASS_MARKERS = {'static': 'o', 'approaching': '^', 'receding': 'v',
                 'crossing': 's'}

# Sequential blue, steps 100 -> 700, light means near zero.
SEQUENTIAL = LinearSegmentedColormap.from_list('isolde_blue', [
    SURFACE, '#cde2fb', '#9ec5f4', '#6da7ec', '#3987e5', '#2a78d6',
    '#256abf', '#184f95', '#0d366b'])


def style():
    plt.rcParams.update({
        'figure.facecolor': SURFACE, 'axes.facecolor': SURFACE,
        'savefig.facecolor': SURFACE, 'text.color': INK,
        'axes.labelcolor': INK_SECONDARY, 'axes.edgecolor': GRID,
        'xtick.color': INK_SECONDARY, 'ytick.color': INK_SECONDARY,
        'axes.titlecolor': INK, 'grid.color': GRID, 'grid.linewidth': 0.6,
        'axes.linewidth': 0.8, 'font.size': 8, 'axes.titlesize': 9,
        'legend.frameon': False, 'figure.dpi': 140,
    })


def examples(seed=12):
    """One representative sequence per class, with its raw maps kept."""
    out = {}
    for index, name in enumerate(rs.CLASSES):
        rng = np.random.default_rng(seed + 17 * index)
        out[name] = rs.make_sequence(rng, index)
    return out


def power_db(cr, ci):
    """Display uses the same max(|Cr|,|Ci|) proxy the firmware would compute."""
    mag = rs.magnitude_proxy(cr, ci).astype(np.float64)
    return 20.0 * np.log10(np.maximum(mag, 1e-6))


def plot_scene_maps(data, path, frames=(0, 2, 4, 6, 8, 10)):
    fig, axes = plt.subplots(len(rs.CLASSES), len(frames),
                             figsize=(2.05 * len(frames), 1.95 * len(rs.CLASSES)),
                             sharex=True, sharey=True)
    extent = [rs.ANGLES[0], rs.ANGLES[-1], rs.RANGES[-1], rs.RANGES[0]]
    for row, name in enumerate(rs.CLASSES):
        seq = data[name]
        db = power_db(seq['cr'], seq['ci'])
        top = db.max()
        for col, frame in enumerate(frames):
            ax = axes[row, col]
            ax.imshow(db[frame].T, aspect='auto', extent=extent,
                      cmap=SEQUENTIAL, vmin=top + rs.LOG_FLOOR_DB, vmax=top,
                      interpolation='nearest')
            ax.plot(seq['track']['angle_deg'][frame],
                    seq['track']['range_m'][frame], marker='o', markersize=7,
                    markerfacecolor='none', markeredgewidth=1.2,
                    markeredgecolor=CLASS_COLOURS[name])
            if row == 0:
                ax.set_title(f't = {frame * rs.DT:.2f} s', pad=4)
            if col == 0:
                ax.set_ylabel(f'{name}\nrange (m)',
                              color=CLASS_COLOURS[name], fontsize=8.5)
            if row == len(rs.CLASSES) - 1:
                ax.set_xlabel('bearing (deg)')
            ax.tick_params(length=2)
    fig.suptitle('What the beamformer sees: range-angle power, '
                 f'{rs.LOG_FLOOR_DB:.0f} dB display range, '
                 'circle marks the true target', y=0.995, fontsize=9.5)
    fig.tight_layout(rect=(0, 0, 1, 0.975))
    fig.savefig(path)
    plt.close(fig)


def plot_features(data, path):
    fig, axes = plt.subplots(1, len(rs.CLASSES),
                             figsize=(2.6 * len(rs.CLASSES), 3.1), sharey=True)
    for ax, name in zip(axes, rs.CLASSES):
        x = data[name]['features'].astype(np.float64)
        ax.imshow(x, aspect='auto', cmap=SEQUENTIAL, vmin=0.0, vmax=1.0,
                  interpolation='nearest',
                  extent=[0, rs.N_FEATURES, rs.N_FRAMES - 0.5, -0.5])
        ax.axvline(rs.N_ANGLE_FEATURES, color=SURFACE, linewidth=2.0)
        ax.set_title(name, color=CLASS_COLOURS[name])
        ax.set_xticks([rs.N_ANGLE_FEATURES / 2,
                       rs.N_ANGLE_FEATURES + rs.N_BINS / 2])
        ax.set_xticklabels(['bearing\n(16)', 'range\n(16)'])
        ax.tick_params(length=0)
        ax.set_xlabel('feature', labelpad=2)
    axes[0].set_ylabel('frame')
    axes[0].set_yticks(range(0, rs.N_FRAMES, 2))
    fig.suptitle('Encoder input: 12 frames x 32 features, '
                 'peak-normalised log magnitude', fontsize=9.5)
    fig.tight_layout(rect=(0, 0, 1, 0.94))
    fig.savefig(path)
    plt.close(fig)


def plot_class_separation(blob, path):
    fig, ax = plt.subplots(figsize=(6.4, 4.2))
    ax.set_axisbelow(True)
    ax.grid(True, linewidth=0.6)
    for index, name in enumerate(rs.CLASSES):
        spec = rs.CLASS_SPEC[name]
        (rlo, rhi), (alo, ahi) = spec['delta_range_bins'], spec['delta_angle']
        ax.add_patch(Rectangle((rlo, alo), rhi - rlo, ahi - alo, fill=False,
                               edgecolor=CLASS_COLOURS[name], linewidth=1.0,
                               linestyle=(0, (4, 3)), zorder=2))
        mask = blob['train_y'] == index
        dr = blob['train_delta_range_bins'][mask]
        da = blob['train_delta_angle'][mask]
        ax.scatter(dr, da, s=9, marker=CLASS_MARKERS[name], linewidths=0,
                   color=CLASS_COLOURS[name], alpha=0.55, zorder=3)
        # Label the band, not the cloud, so text never lands on the marks.
        ax.annotate(name, ((rlo + rhi) / 2.0, ahi), textcoords='offset points',
                    xytext=(0, 6), ha='center', fontsize=9,
                    color=CLASS_COLOURS[name], zorder=4)
    ax.set_ylim(-3.5, 70.0)
    ax.set_xlabel('range change over the window (bins, negative = closing)')
    ax.set_ylabel('bearing change over the window (deg)')
    ax.set_title('Class definitions are disjoint bands on the realised track\n'
                 'dashed rectangles are CLASS_SPEC; every sample lies inside '
                 'exactly one', loc='left', color=INK_SECONDARY, fontsize=9)
    fig.tight_layout()
    fig.savefig(path)
    plt.close(fig)


def plot_tracks(path, per_class=40, seed=101):
    # Share y within each row: comparing panels is the whole point of the
    # figure, and per-panel scales would make every class look the same.
    fig, axes = plt.subplots(2, len(rs.CLASSES),
                             figsize=(2.55 * len(rs.CLASSES), 4.3),
                             sharex=True, sharey='row')
    t = rs.DT * np.arange(rs.N_FRAMES)
    for col, name in enumerate(rs.CLASSES):
        rng = np.random.default_rng(seed + 31 * col)
        colour = CLASS_COLOURS[name]
        for _ in range(per_class):
            track = rs.sample_track(rng, rs.CLASSES.index(name))
            axes[0, col].plot(t, track['range_m'] / rs.RANGE_BIN_M - 1.0,
                              color=colour, linewidth=0.8, alpha=0.35)
            axes[1, col].plot(t, track['angle_deg'], color=colour,
                              linewidth=0.8, alpha=0.35)
        axes[0, col].set_title(name, color=colour)
        for row in (0, 1):
            axes[row, col].grid(True, linewidth=0.6)
            axes[row, col].set_axisbelow(True)
        axes[1, col].set_xlabel('time (s)')
    axes[0, 0].set_ylabel('range bin')
    axes[1, 0].set_ylabel('bearing (deg)')
    fig.suptitle('Constant-velocity tracks behind each class '
                 f'({per_class} per class)', fontsize=9.5)
    fig.tight_layout(rect=(0, 0, 1, 0.945))
    fig.savefig(path)
    plt.close(fig)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--out-dir', type=Path, default=Path('results'))
    parser.add_argument('--data', type=Path,
                        default=Path('results/radar_sequences.npz'))
    args = parser.parse_args()
    style()
    args.out_dir.mkdir(parents=True, exist_ok=True)

    data = examples()
    plot_scene_maps(data, args.out_dir / 'scene_maps.png')
    plot_features(data, args.out_dir / 'features.png')
    plot_tracks(args.out_dir / 'tracks.png')
    plot_class_separation(np.load(args.data),
                          args.out_dir / 'class_separation.png')
    for name in ('scene_maps', 'features', 'tracks', 'class_separation'):
        print('wrote', args.out_dir / f'{name}.png')


if __name__ == '__main__':
    main()
