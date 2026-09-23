#!/usr/bin/env python3
"""Validate and plot radar_attention UART output.

Consumes the `[TFORMER]` / `[TFWIN]` / `[TFLOG]` / `[TFMAP]` lines the firmware
already prints, from a Verilator log or a live serial port.  No firmware or RTL
change is needed.

    python3 tformer_viewer.py --log ../../system/tformer.log
    python3 tformer_viewer.py --port /dev/ttyUSB3 --baud 921600 \
        --capture results/uart_capture.log

The parser rejects a log that is incomplete, duplicated, mismatched to the
exported vectors, or that reports FAILED.  It then compares every received
value against the golden in `inc/` and reports the ULP difference per element.

That comparison is the point.  The host mock reproduces the FP16 reference
exactly, but RTL need not: radar_beamforming's own firmware accepts up to
4 ULP against the same style of reference.  A log's origin cannot be inferred
from its contents, so a successful parse of a host-mock log is not an RTL
result.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import radar_scene as rs                                           # noqa: E402

HEADER = re.compile(r'\[TFORMER\] case=([0-9a-fA-F]+) weights=([0-9a-fA-F]+) '
                    r'mode=(\w+)')
SHAPE = re.compile(r'\[TFORMER\] frames=(\d+) features=(\d+) d_model=(\d+) '
                   r'd_ff=(\d+) layers=(\d+)')
COST = re.compile(r'\[TFORMER\] launches=(\d+) barriers=(\d+)')
WINDOW = re.compile(r'\[TFWIN\]\s+(\d+)\s+([0-9a-fA-F]{4})')
LOGIT = re.compile(r'\[TFLOG\]\s+(\d+)\s+([0-9a-fA-F]{4})')
MAP_HEADER = re.compile(r'\[TFMAPHDR\] frame=(\d+) beams=(\d+) bins=(\d+)')
MAP = re.compile(r'\[TFMAP\]\s+(\d+)\s+([0-9a-fA-F]{4})\s+([0-9a-fA-F]{4})')
CLASSES = rs.CLASSES


# ---------------------------------------------------------------------------
# Golden vectors, read straight out of the generated headers.
# ---------------------------------------------------------------------------
def header_array(text, name):
    body = text.split(f'{name}[')[1].split('= {')[1].split('};')[0]
    return np.array([int(v, 16) for v in re.findall(r'0x([0-9a-f]{4})', body)],
                    dtype=np.uint16)


def header_define(text, name, cast=str):
    match = re.search(rf'#define {name}\s+"?([^"\s]+)"?', text)
    if match is None:
        raise ValueError(f'{name} missing from the generated header')
    return cast(match.group(1))


def load_golden(header_dir, weights_name='tformer_weights.h'):
    vectors = (header_dir / 'tformer_vectors.h').read_text()
    weights = (header_dir / weights_name).read_text()
    # Same guard the firmware applies at startup: a stale pair would compare
    # correct output against another configuration's answers.
    if header_define(vectors, 'TF_CASE_ID') != \
            header_define(weights, 'TF_GOLDEN_CASE_ID'):
        raise ValueError(f'{weights_name} was exported for case '
                         f'{header_define(weights, "TF_GOLDEN_CASE_ID")} but '
                         f'tformer_vectors.h holds case '
                         f'{header_define(vectors, "TF_CASE_ID")}; '
                         're-run make model')
    return dict(
        case_id=header_define(vectors, 'TF_CASE_ID'),
        weights_id=header_define(weights, 'TF_WEIGHTS_ID'),
        true_class=header_define(vectors, 'TF_TRUE_CLASS', lambda v: int(v[:-1])),
        predicted=header_define(weights, 'TF_PREDICTED_CLASS',
                                lambda v: int(v[:-1])),
        golden_case_id=header_define(weights, 'TF_GOLDEN_CASE_ID'),
        frames=header_define(weights, 'TF_FRAMES', lambda v: int(v[:-1])),
        classes=header_define(weights, 'TF_CLASSES', lambda v: int(v[:-1])),
        launches=header_define(weights, 'TF_LAUNCHES', lambda v: int(v[:-1])),
        barriers=header_define(weights, 'TF_BARRIERS', lambda v: int(v[:-1])),
        window=header_array(vectors, 'tf_features'),
        logits=header_array(weights, 'tf_logits_golden'),
    )


# ---------------------------------------------------------------------------
# Log parsing
# ---------------------------------------------------------------------------
def collect(pattern, text, count, label, groups=1):
    """Indexed samples, rejecting duplicates, gaps and out-of-range indices."""
    out = np.zeros((count, groups), dtype=np.uint16)
    seen = set()
    for match in pattern.finditer(text):
        index = int(match.group(1))
        if index in seen:
            raise ValueError(f'duplicate {label} sample at index {index}')
        if not 0 <= index < count:
            raise ValueError(f'out-of-range {label} index {index}')
        seen.add(index)
        for g in range(groups):
            out[index, g] = int(match.group(2 + g), 16)
    if len(seen) != count:
        raise ValueError(f'incomplete {label} dump: {len(seen)} of {count}')
    return out if groups > 1 else out[:, 0]


def parse_log(path_or_text, golden):
    text = (path_or_text.read_text(errors='replace')
            if isinstance(path_or_text, Path) else path_or_text)

    header = HEADER.findall(text)
    if len(header) != 1:
        raise ValueError('log metadata missing or repeated')
    case_id, weights_id, mode = header[0]
    if case_id != golden['case_id']:
        raise ValueError(f'case {case_id} does not match the exported vectors '
                         f'({golden["case_id"]}); regenerate or point --inc '
                         'at the headers this firmware was built from')
    if weights_id != golden['weights_id']:
        raise ValueError(f'weights {weights_id} do not match the exported '
                         f'model ({golden["weights_id"]})')

    if '[TFORMER] PASSED' not in text or '[TFORMER] FAILED' in text:
        raise ValueError('firmware did not report PASSED')

    shape = SHAPE.search(text)
    if shape is None:
        raise ValueError('shape line missing')
    frames, features = int(shape.group(1)), int(shape.group(2))
    if frames != golden['frames']:
        raise ValueError('frame count disagrees with the exported model')

    cost = COST.search(text)
    launches, barriers = (int(cost.group(1)), int(cost.group(2))) if cost \
        else (None, None)

    window = collect(WINDOW, text, 2 * frames * 16, 'TFWIN')
    logits = collect(LOGIT, text, golden['classes'], 'TFLOG')

    power_map = None
    map_header = MAP_HEADER.search(text)
    if map_header:
        beams, bins = int(map_header.group(2)), int(map_header.group(3))
        pair = collect(MAP, text, beams * bins, 'TFMAP', groups=2)
        power_map = dict(frame=int(map_header.group(1)),
                         cr=pair[:, 0].reshape(beams, bins),
                         ci=pair[:, 1].reshape(beams, bins))

    if not np.isfinite(window.view(np.float16).astype(np.float32)).all():
        raise ValueError('non-finite value in the feature window')
    if not np.isfinite(logits.view(np.float16).astype(np.float32)).all():
        raise ValueError('non-finite logit')

    return dict(case_id=case_id, weights_id=weights_id, mode=mode,
                frames=frames, features=features, launches=launches,
                barriers=barriers, window=window, logits=logits,
                power_map=power_map,
                feature_errors=_feature_errors(text))


def _feature_errors(text):
    match = re.search(r'feature_errors=(\d+)', text)
    return int(match.group(1)) if match else None


# ---------------------------------------------------------------------------
# Comparison
# ---------------------------------------------------------------------------
def ordered(bits):
    """Monotonic unsigned key for binary16, the same map the firmware uses."""
    bits = bits.astype(np.int32)
    return np.where(bits & 0x8000, 0x8000 - (bits & 0x7fff), 0x8000 + bits)


def ulp(actual, golden):
    return np.abs(ordered(actual) - ordered(golden)).astype(np.int32)


def compare(received, golden):
    window_ulp = ulp(received['window'], golden['window'])
    logit_ulp = ulp(received['logits'], golden['logits'])
    values = received['logits'].view(np.float16).astype(np.float64)
    order = np.argsort(ordered(received['logits']))[::-1]
    return dict(
        window_ulp=window_ulp,
        logit_ulp=logit_ulp,
        worst_window_ulp=int(window_ulp.max()),
        worst_logit_ulp=int(logit_ulp.max()),
        window_exact=bool((window_ulp == 0).all()),
        predicted=int(order[0]),
        margin=float(values[order[0]] - values[order[1]]),
        agrees_with_golden=int(order[0]) == golden['predicted'],
    )


def report(received, golden, result):
    lines = [
        f'case            {received["case_id"]}',
        f'weights         {received["weights_id"]}',
        f'mode            {received["mode"]}',
        f'launches        {received["launches"]} '
        f'(exported {golden["launches"]})',
        f'barriers        {received["barriers"]} '
        f'(exported {golden["barriers"]})',
        f'feature window  {"exact" if result["window_exact"] else "DIFFERS"}, '
        f'worst {result["worst_window_ulp"]} ULP over '
        f'{received["window"].size} values',
        f'logits          worst {result["worst_logit_ulp"]} ULP',
        f'decision        {CLASSES[result["predicted"]]} '
        f'(true {CLASSES[golden["true_class"]]}), margin '
        f'{result["margin"]:.3f}',
    ]
    if received['feature_errors'] is not None:
        lines.append(f'front end        feature_errors='
                     f'{received["feature_errors"]} (must be 0)')
    for i, name in enumerate(CLASSES[:golden['classes']]):
        got = received['logits'][i:i + 1].view(np.float16)[0]
        want = golden['logits'][i:i + 1].view(np.float16)[0]
        lines.append(f'  {name:<12} {received["logits"][i]:04x} vs '
                     f'{golden["logits"][i]:04x}  {result["logit_ulp"][i]} ULP'
                     f'   {float(got):9.4f} vs {float(want):9.4f}')
    return '\n'.join(lines)


# ---------------------------------------------------------------------------
# Plot
# ---------------------------------------------------------------------------
def plot(path, received, golden, result):
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    import plot_scenes as ps

    ps.style()
    frames = received['frames']
    window = received['window'].view(np.float16).reshape(2, frames, 16)
    flat = np.concatenate([window[0], window[1]], axis=1).astype(np.float64)
    has_map = received['power_map'] is not None

    columns = 3 + (1 if has_map else 0)
    widths = ([1.35, 1.0, 1.15] + ([1.35] if has_map else []))
    fig, axes = plt.subplots(1, columns, figsize=(3.3 * columns, 3.6),
                             gridspec_kw=dict(width_ratios=widths))

    ax = axes[0]
    ax.imshow(flat, aspect='auto', cmap=ps.SEQUENTIAL, vmin=0.0, vmax=1.0,
              interpolation='nearest',
              extent=[0, 32, frames - 0.5, -0.5])
    ax.axvline(16, color=ps.SURFACE, linewidth=2.0)
    ax.set_title('received feature window')
    ax.set_xticks([8, 24])
    ax.set_xticklabels(['bearing', 'range'])
    ax.set_ylabel('frame')
    ax.set_yticks(range(0, frames, 2))
    ax.tick_params(length=0)

    ax = axes[1]
    difference = result['window_ulp'].reshape(2, frames, 16)
    difference = np.concatenate([difference[0], difference[1]], axis=1)
    top = max(1, int(difference.max()))
    ax.imshow(difference, aspect='auto', cmap=ps.SEQUENTIAL, vmin=0, vmax=top,
              interpolation='nearest', extent=[0, 32, frames - 0.5, -0.5])
    ax.axvline(16, color=ps.SURFACE, linewidth=2.0)
    ax.set_title('ULP vs golden')
    ax.set_xticks([])
    ax.set_yticks([])
    if result['window_exact']:
        ax.text(16, frames / 2 - 0.5, 'bit exact', ha='center', va='center',
                fontsize=11, color=ps.INK)

    ax = axes[2]
    values = received['logits'].view(np.float16).astype(np.float64)
    names = list(CLASSES[:golden['classes']])
    colours = [ps.CLASS_COLOURS['approaching'] if i == result['predicted']
               else '#9ec5f4' for i in range(len(names))]
    ax.barh(range(len(names)), values, color=colours, height=0.62)
    ax.set_yticks(range(len(names)))
    ax.set_yticklabels(names)
    ax.invert_yaxis()
    ax.axvline(0, color=ps.GRID, linewidth=0.8)
    ax.grid(True, axis='x', linewidth=0.6)
    ax.set_axisbelow(True)
    ax.set_xlabel('logit')
    ax.set_title(f'decision: {names[result["predicted"]]}'
                 f'   margin {result["margin"]:.2f}')
    for i, value in enumerate(values):
        offset = 4 if value >= 0 else -4
        ax.annotate(f'{value:.2f}', (value, i), textcoords='offset points',
                    xytext=(offset, 0), va='center',
                    ha='left' if value >= 0 else 'right',
                    fontsize=8, color=ps.INK_SECONDARY)
    # Value labels sit outside the bar end, so leave room on whichever side
    # actually has bars; otherwise the leftmost label lands on the tick text.
    span = max(abs(values.min()), abs(values.max()))
    ax.set_xlim(-1.55 * span if values.min() < 0 else -0.05 * span,
                1.45 * span if values.max() > 0 else 0.05 * span)

    if has_map:
        ax = axes[3]
        power = received['power_map']
        magnitude = np.maximum(np.abs(power['cr'].view(np.float16)),
                               np.abs(power['ci'].view(np.float16)))
        decibels = 20.0 * np.log10(np.maximum(magnitude.astype(np.float64),
                                              1e-6))
        ax.imshow(decibels.T, aspect='auto', cmap=ps.SEQUENTIAL,
                  vmin=decibels.max() + rs.LOG_FLOOR_DB, vmax=decibels.max(),
                  interpolation='nearest',
                  extent=[rs.ANGLES[0], rs.ANGLES[-1], rs.RANGES[-1],
                          rs.RANGES[0]])
        ax.set_title(f'beamformer, frame {power["frame"]}')
        ax.set_xlabel('bearing (deg)')
        ax.set_ylabel('range (m)')

    fig.suptitle(f'radar_attention from UART   case {received["case_id"]}   '
                 f'mode {received["mode"]}   '
                 f'worst {max(result["worst_window_ulp"], result["worst_logit_ulp"])} ULP',
                 fontsize=9.5)
    fig.tight_layout(rect=(0, 0, 1, 0.93))
    path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(path)
    plt.close(fig)


# ---------------------------------------------------------------------------
def capture_serial(port, baud, timeout, destination=None):
    """Read until the firmware reports PASSED or FAILED."""
    import serial                                  # pyserial, optional

    text = []
    with serial.Serial(port, baud, timeout=timeout) as link:
        while True:
            line = link.readline()
            if not line:
                raise TimeoutError('no UART data; check port, baud and reset')
            text.append(line.decode('ascii', errors='replace'))
            if '[TFORMER] PASSED' in text[-1] or '[TFORMER] FAILED' in text[-1]:
                break
    joined = ''.join(text)
    if destination is not None:
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(joined)
    return joined


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--log', type=Path, help='Verilator or captured log')
    source.add_argument('--port', help='serial device, e.g. /dev/ttyUSB3')
    parser.add_argument('--baud', type=int, default=921600)
    parser.add_argument('--timeout', type=float, default=30.0)
    parser.add_argument('--capture', type=Path,
                        help='write the raw serial text here')
    parser.add_argument('--inc', type=Path, default=Path('inc'),
                        help='headers the firmware was built from')
    parser.add_argument('--weights-name', default='tformer_weights.h')
    parser.add_argument('--out-dir', type=Path, default=Path('results/from_log'))
    args = parser.parse_args()

    golden = load_golden(args.inc, args.weights_name)
    text = (args.log if args.log else
            capture_serial(args.port, args.baud, args.timeout, args.capture))
    received = parse_log(text, golden)
    result = compare(received, golden)

    print(report(received, golden, result))
    plot(args.out_dir / 'tformer_from_log.png', received, golden, result)
    args.out_dir.mkdir(parents=True, exist_ok=True)
    (args.out_dir / 'tformer_from_log.json').write_text(json.dumps(dict(
        case_id=received['case_id'], weights_id=received['weights_id'],
        mode=received['mode'], launches=received['launches'],
        barriers=received['barriers'],
        worst_window_ulp=result['worst_window_ulp'],
        worst_logit_ulp=result['worst_logit_ulp'],
        window_exact=result['window_exact'],
        predicted=CLASSES[result['predicted']],
        true_class=CLASSES[golden['true_class']],
        margin=result['margin'],
        agrees_with_golden=result['agrees_with_golden'],
        feature_errors=received['feature_errors']), indent=2) + '\n')
    print('wrote', args.out_dir / 'tformer_from_log.png')

    if not result['agrees_with_golden']:
        print('DECISION DIFFERS FROM THE GOLDEN', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
