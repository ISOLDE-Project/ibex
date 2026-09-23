#!/usr/bin/env python3
"""Train the radar_attention encoder, fold its constants, export FP16 headers.

The model is shaped so that every matrix product is one native RedMulE tile,
`Z[12x16] = X[12x16] . W[16x16] (+ Y)`:

    proj        X[12x32] . We[32x16] + pos      2 K-tiles
    per layer   Q, K, V                         3 tiles, one per RedMulE
                S = Q . K^T                     K^T padded to 16x16
                A = ReLU(S)                     sign-bit mask on the core
                O = A . V                       V padded to 16 rows
                H = O . Wo + H                  residual preloaded into Y
                U = H . W1                      3 N-tiles, one per RedMulE
                R = ReLU(U)                     sign-bit mask
                H = R . W2 + H                  3 K-tiles, accumulated in Y
    pool        POOL . H                        constant 1/12 matrix
    head        pooled . Wc                     logits in row 0, columns 0..3

Three scalars are folded into the weights at export and therefore cost nothing
on hardware: `1/sqrt(d_model)` into `Wq`, the ReLU-attention scale `s/L` into
`Wv`, and the pooling `1/12` into the constant POOL matrix.

`forward_fp16` reproduces the firmware exactly, including the accumulation
order and the FP16 rounding after every reduction step, so the exported golden
vectors are what the RTL should produce and not a float32 approximation.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

import radar_scene as rs

D_MODEL, N_CLASSES = 16, 4
TILE_M, TILE_N = 12, 16


# ---------------------------------------------------------------------------
# Torch model.  Structure mirrors forward_fp16 below, op for op.
# ---------------------------------------------------------------------------
class Encoder(nn.Module):
    def __init__(self, n_features=rs.N_FEATURES, frames=rs.N_FRAMES,
                 layers=2, d_ff=48):
        super().__init__()
        self.layers, self.d_ff = layers, d_ff
        self.proj = nn.Linear(n_features, D_MODEL, bias=False)
        self.pos = nn.Parameter(torch.zeros(frames, D_MODEL))
        nn.init.normal_(self.pos, std=0.02)
        self.gate = nn.Parameter(torch.full((layers,), float(np.log(frames))))
        self.attn = nn.ModuleList(nn.ModuleDict(dict(
            q=nn.Linear(D_MODEL, D_MODEL, bias=False),
            k=nn.Linear(D_MODEL, D_MODEL, bias=False),
            v=nn.Linear(D_MODEL, D_MODEL, bias=False),
            o=nn.Linear(D_MODEL, D_MODEL, bias=False))) for _ in range(layers))
        self.mlp = nn.ModuleList(nn.Sequential(
            nn.Linear(D_MODEL, d_ff, bias=False), nn.ReLU(),
            nn.Linear(d_ff, D_MODEL, bias=False)) for _ in range(layers))
        self.head = nn.Linear(D_MODEL, N_CLASSES, bias=False)

    def forward(self, x):
        length = x.shape[1]
        h = self.proj(x) + self.pos
        for i, (attn, mlp) in enumerate(zip(self.attn, self.mlp)):
            q, k, v = attn['q'](h), attn['k'](h), attn['v'](h)
            scores = q @ k.transpose(1, 2) / D_MODEL ** 0.5
            weights = F.relu(scores) * (self.gate[i].exp() / length)
            h = h + attn['o'](weights @ v)
            h = h + mlp(h)
        return self.head(h.mean(dim=1))


# ---------------------------------------------------------------------------
# FP16 reference.  One call == one RedMulE launch.
# ---------------------------------------------------------------------------
def gemm(x, w, y=None):
    """Z = X . W + Y with FP16 rounding after each of the 16 reduction steps.

    Same arithmetic as radar_beamforming's real_accumulate, which the RTL
    reference in that package is written against.
    """
    x = np.asarray(x, dtype=np.float16)
    w = np.asarray(w, dtype=np.float16)
    out = (np.zeros((x.shape[0], w.shape[1]), dtype=np.float16)
           if y is None else np.array(y, dtype=np.float16, copy=True))
    for n in range(x.shape[1]):
        out = (x[:, n, None].astype(np.float32) * w[None, n, :].astype(np.float32)
               + out.astype(np.float32)).astype(np.float16)
    return out


def relu_fp16(a):
    """Clearing the sign bit's row: on Ibex this is `h &= ~-(h >> 15)`."""
    bits = np.ascontiguousarray(a, dtype=np.float16).view(np.uint16)
    return np.where(bits & np.uint16(0x8000), np.uint16(0),
                    bits).astype(np.uint16).view(np.float16)


def pad_rows(a, rows=TILE_N):
    out = np.zeros((rows, a.shape[1]), dtype=np.float16)
    out[:a.shape[0]] = a
    return out


class Weights:
    """Folded FP16 weights, in exactly the tile shapes the firmware uploads."""

    def __init__(self, proj, pos, layers, pool, head, d_ff):
        self.proj, self.pos, self.layers = proj, pos, layers
        self.pool, self.head, self.d_ff = pool, head, d_ff

    @classmethod
    def from_torch(cls, model, frames=rs.N_FRAMES):
        def half(t):
            return np.ascontiguousarray(t.detach().numpy(), dtype=np.float16)

        scale_q = 1.0 / np.sqrt(D_MODEL)
        layers = []
        for i, (attn, mlp) in enumerate(zip(model.attn, model.mlp)):
            scale_v = float(model.gate[i].detach().exp() / frames)
            # W1 is [d_model, d_ff]: the firmware needs each 16-column N-tile
            # contiguous, so store it as [tiles][16][16].  W2 is [d_ff, d_model]
            # and its 16-row K-tiles are already contiguous.
            w1 = half(mlp[0].weight.T)
            tiles = w1.shape[1] // TILE_N
            layers.append(dict(
                wq=half(attn['q'].weight.T * scale_q),
                wk=half(attn['k'].weight.T),
                wv=half(attn['v'].weight.T * scale_v),
                wo=half(attn['o'].weight.T),
                w1=np.ascontiguousarray(
                    w1.reshape(D_MODEL, tiles, TILE_N).transpose(1, 0, 2)),
                w2=np.ascontiguousarray(
                    half(mlp[2].weight.T).reshape(tiles, TILE_N, D_MODEL))))
        pool = np.zeros((TILE_M, TILE_N), dtype=np.float16)
        pool[:, :frames] = np.float16(1.0 / frames)
        head = np.zeros((D_MODEL, TILE_N), dtype=np.float16)
        head[:, :N_CLASSES] = half(model.head.weight.T)
        return cls(half(model.proj.weight.T), half(model.pos), layers,
                   pool, head, model.d_ff)

    @property
    def n_layers(self):
        return len(self.layers)

    def parameter_count(self):
        total = self.proj.size + self.pos.size + self.pool.size + self.head.size
        for layer in self.layers:
            total += sum(v.size for v in layer.values())
        return total


def forward_fp16(weights, window, trace=None):
    """window[12, 32] FP16 -> logits[4].  `trace` collects per-stage goldens."""
    window = np.asarray(window, dtype=np.float16)

    def record(name, value):
        if trace is not None:
            trace[name] = np.array(value, dtype=np.float16, copy=True)

    h = weights.pos
    for k in range(window.shape[1] // TILE_N):            # 2 K-tiles
        h = gemm(window[:, k * TILE_N:(k + 1) * TILE_N],
                 weights.proj[k * TILE_N:(k + 1) * TILE_N], h)
    record('proj', h)

    for index, layer in enumerate(weights.layers):
        q = gemm(h, layer['wq'])
        k = gemm(h, layer['wk'])
        v = gemm(h, layer['wv'])
        record(f'l{index}_q', q)
        record(f'l{index}_v', v)

        kt = np.zeros((TILE_N, TILE_N), dtype=np.float16)
        kt[:, :TILE_M] = k.T                              # uint16 moves only
        s = gemm(q, kt)
        a = relu_fp16(s)
        record(f'l{index}_attn', a)

        o = gemm(a, pad_rows(v))
        h = gemm(o, layer['wo'], h)                       # residual through Y
        record(f'l{index}_attn_out', h)

        tiles = weights.d_ff // TILE_N
        r = np.stack([relu_fp16(gemm(h, layer['w1'][t])) for t in range(tiles)])
        record(f'l{index}_ff', r)
        for t in range(tiles):                            # K-accumulate into Y
            h = gemm(r[t], layer['w2'][t], h)
        record(f'l{index}_out', h)

    pooled = gemm(weights.pool, pad_rows(h))
    record('pooled', pooled)
    logits = gemm(pooled, weights.head)
    record('logits', logits)
    return logits[0, :N_CLASSES]


def launch_counts(weights, frames=rs.N_FRAMES, n_features=rs.N_FEATURES):
    """What the firmware schedule costs, derived from the same structure."""
    tiles_ff = weights.d_ff // TILE_N
    per_layer_launches = 3 + 1 + 1 + 1 + tiles_ff + tiles_ff
    per_layer_barriers = 1 + 1 + 1 + 1 + 1 + tiles_ff
    k_tiles = n_features // TILE_N
    del frames
    return dict(
        launches=k_tiles + weights.n_layers * per_layer_launches + 2,
        barriers=k_tiles + weights.n_layers * per_layer_barriers + 2)


# ---------------------------------------------------------------------------
# Training
# ---------------------------------------------------------------------------
def load_splits(path):
    blob = np.load(path)
    out = {}
    for short, name in (('tr', 'train'), ('va', 'val'), ('te', 'test')):
        out['x' + short] = torch.tensor(blob[f'{name}_x'], dtype=torch.float32)
        out['y' + short] = torch.tensor(blob[f'{name}_y'], dtype=torch.long)
    return out, blob


def accuracy(model, x, y):
    model.eval()
    with torch.no_grad():
        return (model(x).argmax(1) == y).float().mean().item()


def train(model, data, epochs, lr, seed):
    # The seed must also be set before the model is constructed; see main().
    torch.manual_seed(seed)
    opt = torch.optim.AdamW(model.parameters(), lr=lr, weight_decay=1e-2)
    steps = epochs * max(1, len(data['xtr']) // 128)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=lr, total_steps=steps)
    best, best_state = 0.0, None
    for _ in range(epochs):
        model.train()
        order = torch.randperm(len(data['xtr']))
        for i in range(0, len(order) - 127, 128):
            index = order[i:i + 128]
            loss = F.cross_entropy(model(data['xtr'][index]), data['ytr'][index])
            opt.zero_grad()
            loss.backward()
            opt.step()
            sched.step()
        val = accuracy(model, data['xva'], data['yva'])
        if val > best:
            best = val
            best_state = {k: v.clone() for k, v in model.state_dict().items()}
    model.load_state_dict(best_state)
    return best


def fp16_accuracy(weights, x, y):
    correct = 0
    for i in range(len(x)):
        logits = forward_fp16(weights, x[i].numpy().astype(np.float16))
        correct += int(np.argmax(logits.astype(np.float32)) == int(y[i]))
    return correct / len(x)


# ---------------------------------------------------------------------------
# Header emission.  Same format as radar_beamforming/beamforming.py.
# ---------------------------------------------------------------------------
def array_lines(name, values, comment=None):
    raw = np.ascontiguousarray(values, dtype=np.float16).view(np.uint16).ravel()
    lines = []
    if comment:
        lines.append(f'/* {comment} */')
    lines.append(f'static const uint16_t {name}[{len(raw)}] '
                 '__attribute__((aligned(16))) = {')
    lines += ['  ' + ', '.join(f'0x{int(v):04x}' for v in raw[i:i + 8]) + ','
              for i in range(0, len(raw), 8)]
    lines.append('};')
    return lines


def emit_weights_header(path, weights, case_id, golden):
    counts = launch_counts(weights)
    guard = path.name.upper().replace('.', '_').replace('-', '_')
    lines = ['/* Generated by tformer.py; IEEE binary16 raw storage. */',
             f'#ifndef {guard}', f'#define {guard}',
             '#include <stdint.h>', '',
             f'#define TF_FRAMES {rs.N_FRAMES}u',
             f'#define TF_FEATURES {rs.N_FEATURES}u',
             f'#define TF_DMODEL {D_MODEL}u',
             f'#define TF_DFF {weights.d_ff}u',
             f'#define TF_LAYERS {weights.n_layers}u',
             f'#define TF_CLASSES {N_CLASSES}u',
             f'#define TF_LAUNCHES {counts["launches"]}u',
             f'#define TF_BARRIERS {counts["barriers"]}u',
             f'#define TF_WEIGHTS_ID "{case_id}"',
             f'#define TF_WEIGHT_BYTES {weights.parameter_count() * 2}u',
             f'#define TF_GOLDEN_CASE_ID "{golden["case_id"]}"',
             f'#define TF_PREDICTED_CLASS {golden["predicted"]}u', '',
             '/* 1/sqrt(d_model) is folded into wq, the ReLU-attention scale',
             ' * s/L into wv, and the pooling 1/12 into tf_pool. */', '']
    lines += array_lines('tf_proj', weights.proj, 'X[12x32] . We[32x16]')
    lines += array_lines('tf_pos', weights.pos, 'Y preload of the first K-tile')
    for index, layer in enumerate(weights.layers):
        for key in ('wq', 'wk', 'wv', 'wo', 'w1', 'w2'):
            lines += array_lines(f'tf_l{index}_{key}', layer[key])
    lines += array_lines('tf_pool', weights.pool, 'constant 1/12 mean matrix')
    lines += array_lines('tf_head', weights.head, 'logits land in columns 0..3')
    lines += ['',
              '/* Indexed by the TF_WQ..TF_W2 enum in tformer_runtime.h, so',
              ' * the runtime loops over layers without a generated struct. */',
              'static const uint16_t *const tf_layer[TF_LAYERS][6] = {']
    for index in range(weights.n_layers):
        lines.append('  { ' + ', '.join(f'tf_l{index}_{k}' for k in
                     ('wq', 'wk', 'wv', 'wo', 'w1', 'w2')) + ' },')
    lines += ['};', '']
    # The goldens belong to this model, not to the data case: keeping them
    # here is what stops a second export overwriting the first one's answers.
    lines += array_lines('tf_logits_golden', golden['logits'])
    lines += ['', '/* Per-stage activations. Host mock only: they would eat',
              ' * DMEM the device build needs for weights. */',
              '#ifndef TF_STAGE_GOLDEN', '#define TF_STAGE_GOLDEN 0', '#endif',
              '#if TF_STAGE_GOLDEN']
    for name, value in golden['stages'].items():
        lines += array_lines(f'tf_golden_{name}', value)
    lines += ['#endif', '', '#endif', '']
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text('\n'.join(lines))


def emit_vectors_header(path, case, snapshots, steering):
    lines = ['/* Generated by tformer.py; IEEE binary16 raw storage. */',
             '#ifndef TFORMER_VECTORS_H', '#define TFORMER_VECTORS_H',
             '#include <stdint.h>', '',
             f'#define TF_CASE_ID "{case["case_id"]}"',
             f'#define TF_TRUE_CLASS {case["label"]}u',
             f'#define TF_ANTENNAS {rs.N_ANT}u', '',
             '#ifndef TF_CHAIN', '#define TF_CHAIN 0', '#endif',
             '#ifndef TF_STAGE_GOLDEN', '#define TF_STAGE_GOLDEN 0', '#endif',
             '',
             'static const char *const tf_class_name[TF_CLASSES] = {'
             + ', '.join(f'"{c}"' for c in rs.CLASSES) + '};', '']
    # Tile-major: [0] is the 12x16 bearing tile, [1] the 12x16 range tile.
    # That is exactly the two X operands the projection's K-tiles consume, so
    # the feature front end writes this layout directly.
    window = np.stack([case['features'][:, :TILE_N],
                       case['features'][:, TILE_N:]])
    lines += array_lines('tf_features', window,
                         'encoder input [2][12][16]: bearing tile, range tile')
    lines += ['', '/* Chained mode input: 12 antenna snapshots and the steering',
              ' * matrix, split real/imaginary, as radar_beamforming uses. */',
              '#if TF_CHAIN']
    lines += array_lines('tf_ar', steering['ar'])
    lines += array_lines('tf_ai', steering['ai'])
    lines += array_lines('tf_br', snapshots['br'])
    lines += array_lines('tf_bi', snapshots['bi'])
    lines += ['#endif', '', '#endif', '']
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text('\n'.join(lines))


# ---------------------------------------------------------------------------
def build_case(weights, seed, class_index):
    """One end-to-end case: raw snapshots -> features -> logits -> class."""
    rng = np.random.default_rng(seed)
    sequence = rs.make_sequence(rng, class_index)
    features = sequence['features']
    stages = {}
    logits = forward_fp16(weights, features, trace=stages)

    a = rs.steering_matrix()
    steering = dict(ar=np.ascontiguousarray(a.real, dtype=np.float16),
                    ai=np.ascontiguousarray(a.imag, dtype=np.float16))
    b = sequence['snapshots']
    snapshots = dict(br=np.ascontiguousarray(b.real, dtype=np.float16),
                     bi=np.ascontiguousarray(b.imag, dtype=np.float16))
    digest = hashlib.sha256()
    for key in ('br', 'bi'):
        digest.update(snapshots[key].astype('<f2').tobytes())
    case = dict(features=features, logits=logits,
                label=int(class_index),
                predicted=int(np.argmax(logits.astype(np.float32))),
                case_id=digest.hexdigest()[:16])
    return case, stages, snapshots, steering


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data', type=Path,
                        default=Path('results/radar_sequences.npz'))
    parser.add_argument('--out-dir', type=Path, default=Path('results'))
    parser.add_argument('--header-dir', type=Path, default=Path('inc'))
    parser.add_argument('--weights-name', default='tformer_weights.h',
                        help='file name inside --header-dir; the firmware '
                             'selects it with -DTF_WEIGHTS_HEADER')
    parser.add_argument('--layers', type=int, default=2)
    parser.add_argument('--d-ff', type=int, default=48)
    parser.add_argument('--epochs', type=int, default=80)
    parser.add_argument('--seed', type=int, default=0)
    parser.add_argument('--seeds', type=int, default=1,
                        help='train this many seeds and keep the best one; '
                             'selection is on validation accuracy only')
    parser.add_argument('--case-class', type=int, default=1,
                        help='class index for the exported end-to-end case')
    args = parser.parse_args()

    data, _ = load_splits(args.data)
    model, val, chosen_seed = None, -1.0, args.seed
    for offset in range(args.seeds):
        seed = args.seed + offset
        # Seed before construction: weight init draws from the global RNG, so
        # seeding only inside train() leaves the export irreproducible.
        torch.manual_seed(seed)
        candidate = Encoder(layers=args.layers, d_ff=args.d_ff)
        candidate_val = train(candidate, data, args.epochs, 3e-3, seed)
        if args.seeds > 1:
            print(f'  seed {seed}: val {candidate_val:.4f}')
        # Selection is on validation only; test is reported, never optimised.
        if candidate_val > val:
            model, val, chosen_seed = candidate, candidate_val, seed
    float_test = accuracy(model, data['xte'], data['yte'])

    weights = Weights.from_torch(model)
    half_test = fp16_accuracy(weights, data['xte'], data['yte'])
    counts = launch_counts(weights)

    case, stages, snapshots, steering = build_case(weights, 4242,
                                                   args.case_class)
    weights_id = hashlib.sha256(b''.join(
        np.ascontiguousarray(v, dtype=np.float16).astype('<f2').tobytes()
        for v in [weights.proj, weights.pos, weights.pool, weights.head]
        + [layer[k] for layer in weights.layers
           for k in ('wq', 'wk', 'wv', 'wo', 'w1', 'w2')])).hexdigest()[:16]

    emit_weights_header(args.header_dir / args.weights_name, weights,
                        weights_id,
                        dict(logits=case['logits'], stages=stages,
                             case_id=case['case_id'],
                             predicted=case['predicted']))
    emit_vectors_header(args.header_dir / 'tformer_vectors.h', case,
                        snapshots, steering)

    summary = dict(layers=args.layers, d_ff=args.d_ff, seed=chosen_seed,
                   seeds_tried=args.seeds,
                   parameters=int(weights.parameter_count()),
                   weights_bytes=int(weights.parameter_count()) * 2,
                   weights_id=weights_id, case_id=case['case_id'],
                   val_accuracy=val, float32_test_accuracy=float_test,
                   fp16_test_accuracy=half_test,
                   case_true_class=rs.CLASSES[case['label']],
                   case_predicted_class=rs.CLASSES[case['predicted']],
                   **counts)
    args.out_dir.mkdir(parents=True, exist_ok=True)
    (args.out_dir / 'model_summary.json').write_text(
        json.dumps(summary, indent=2) + '\n')
    for key, value in summary.items():
        print(f'{key:>24}: {value}')


if __name__ == '__main__':
    main()
