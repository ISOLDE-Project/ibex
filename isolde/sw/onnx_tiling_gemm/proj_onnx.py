#!/usr/bin/env python3
"""Standalone ONNX graph for the two-K-tile projection stage of the ISOLDE
radar_attention encoder (tformer_runtime3), i.e. the C fragment:

    launch_bias(0, window, tf_proj, tf_pos);   // Y  = X0 . We0 + pos
    omrm_wait(1u);
    launch_accumulate(0, window + X_ELEMENTS,   // Y += X1 . We1
                      tf_proj + W_ELEMENTS);
    omrm_wait(1u);
    collect(0, h);                             // h  = Y

Mathematically this is the input embedding + learned positional encoding:

    h[12,16] = X[12,32] . We[32,16] + pos[12,16]

The RedMulE runtime splits the K=32 contraction into two 16-wide tiles
(launch_bias then launch_accumulate); a single MatMul over K=32 is the same
value, so the graph uses one MatMul + one Add (onnx-mlir fuses them into one
Gemm and tiles it back into exactly those two launches).   
-- onnx-mlir does not lower onnx.Slice to RedMulE yet.

Standard ai.onnx ops only (no com.isolde domain); runnable in onnxruntime.
IEEE binary16 to match the firmware storage type.

Weights: random (--seed), or the trained encoder's (--weights
tformer_weights.h, optionally with --vectors tformer_vectors.h for its test
window and firmware golden).

--header-dir writes the firmware test data (isolde/sw/onnx_projection):

    proj_window.h   window_inp[12*32]   row-major [12][32], the graph input
    proj_golden.h   h_golden[12*16]     bit-exact RedMulE FP16 result
    tensor_dim.h    FRAMES, FEATURES, D_MODEL

The golden follows the RedMulE arithmetic of radar_attention/tformer.py
(FP16 rounding after each of the 16 reduction steps) and the schedule both the
firmware and onnx-mlir use: Y = pos, then the K-tiles in order.  With
--vectors it is also checked against the firmware's tf_golden_proj.
"""
from __future__ import annotations

import argparse
import re
from pathlib import Path

import numpy as np
import onnx
from onnx import TensorProto, helper, numpy_helper

ONNX_OPSET = 18
IR_VERSION = 9

FRAMES = 12          # TF_FRAMES  (rows of the window / one tile tall)
D_MODEL = 16         # TF_DMODEL  (COLS, one tile wide)
FEATURES = 64        # TF_FEATURES (2 * COLS, two K-tiles)
TILE = 16            # RedMulE K / N


def build_model(proj, pos):
    """proj: We[FEATURES, D_MODEL]; pos: [FRAMES, D_MODEL] (f16 arrays).
    Returns a ModelProto computing h = X.We + pos, X = [FRAMES, FEATURES]."""
    inits, nodes = [], []

    def init(name, value, dtype=np.float16):
        inits.append(numpy_helper.from_array(
            np.ascontiguousarray(value, dtype), name))
        return name

    x = helper.make_tensor_value_info('window', TensorProto.FLOAT16,
                                      [FRAMES, FEATURES])
    h = helper.make_tensor_value_info('h', TensorProto.FLOAT16,
                                      [FRAMES, D_MODEL])

    
        # One MatMul over the full K=32 contraction, then + pos.
    nodes.append(helper.make_node('MatMul', ['window', init('tf_proj', proj)],
                                      ['embedded'], name='input_embedding'))
    nodes.append(helper.make_node('Add', ['embedded', init('tf_pos', pos)],
                                      ['h'], name='positional_encoding'))


    graph = helper.make_graph(nodes, 'projection', [x], [h], initializer=inits)
    model = helper.make_model(
        graph, producer_name='ISOLDE proj_onnx.py',
        ir_version=IR_VERSION,
        opset_imports=[helper.make_opsetid('', ONNX_OPSET)])
    onnx.checker.check_model(model, full_check=True)
    onnx.shape_inference.infer_shapes(model, check_type=True, strict_mode=True)
    return model


# ---------------------------------------------------------------------------
# RedMulE FP16 reference (radar_attention/tformer.py: gemm)
def gemm(x, w, y=None):
    """Z = X . W + Y with FP16 rounding after each reduction step."""
    x = np.asarray(x, dtype=np.float16)
    w = np.asarray(w, dtype=np.float16)
    out = (np.zeros((x.shape[0], w.shape[1]), dtype=np.float16)
           if y is None else np.array(y, dtype=np.float16, copy=True))
    for n in range(x.shape[1]):
        out = (x[:, n, None].astype(np.float32) * w[None, n, :].astype(np.float32)
               + out.astype(np.float32)).astype(np.float16)
    return out


def redmule_projection(window, proj, pos):
    """launch_bias + launch_accumulate: Y = pos; Y = X_k . We_k + Y."""
    h = np.array(pos, dtype=np.float16, copy=True)
    for k in range(FEATURES // TILE):
        h = gemm(window[:, k * TILE:(k + 1) * TILE],
                 proj[k * TILE:(k + 1) * TILE], h)
    return h


# ---------------------------------------------------------------------------
# C header I/O
def read_c_array(path, name):
    """uint16 contents of `static const uint16_t name[N] ... = { ... };`."""
    text = Path(path).read_text()
    m = re.search(r'\b' + re.escape(name) + r'\s*\[\s*(\d+)\s*\][^=]*=\s*\{(.*?)\}',
                  text, re.S)
    if not m:
        raise SystemExit(f'{path}: no array {name}')
    values = [int(v, 0) for v in re.findall(r'0x[0-9a-fA-F]+|\d+', m.group(2))]
    if len(values) != int(m.group(1)):
        raise SystemExit(f'{path}: {name} has {len(values)} of {m.group(1)} values')
    return np.array(values, dtype=np.uint16).view(np.float16)


def write_c_array(path, guard, name, values, comment):
    bits = np.ascontiguousarray(values, dtype=np.float16).view(np.uint16).ravel()
    lines = [f'/* Generated by proj_onnx.py -- {comment} */',
             f'#ifndef {guard}', f'#define {guard}', '',
             '#include <stdint.h>', '',
             f'static const uint16_t {name}[{bits.size}] __attribute__((aligned(16))) = {{']
    for i in range(0, bits.size, 8):
        lines.append('  ' + ', '.join(f'0x{b:04x}' for b in bits[i:i + 8]) + ',')
    lines += ['};', '', f'#endif /* {guard} */', '']
    Path(path).write_text('\n'.join(lines))


def write_headers(out_dir, window, golden, source):
    out_dir.mkdir(parents=True, exist_ok=True)
    write_c_array(out_dir / 'proj_window.h', 'PROJ_WINDOW_H', 'window_inp',
                  window, f'graph input window[{FRAMES}][{FEATURES}], row-major; '
                  + source)
    write_c_array(out_dir / 'proj_golden.h', 'PROJ_GOLDEN_H', 'h_golden',
                  golden, f'h[{FRAMES}][{D_MODEL}], bit-exact RedMulE FP16 '
                  '(Y = pos, then the two K-tiles); ' + source)
    (out_dir / 'tensor_dim.h').write_text('\n'.join([
        '/* Generated by proj_onnx.py */', '#ifndef TENSOR_DIM_H',
        '#define TENSOR_DIM_H', '', f'#define FRAMES {FRAMES}',
        f'#define FEATURES {FEATURES}', f'#define D_MODEL {D_MODEL}', '',
        '#endif /* TENSOR_DIM_H */', '']))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument('--out', type=Path, default=Path('models/proj.onnx'))
    ap.add_argument('--seed', type=int, default=0,
                    help='random weights and window (unless --weights/--vectors)')
    ap.add_argument('--weights', type=Path,
                    help='tformer_weights.h: use its tf_proj / tf_pos')
    ap.add_argument('--vectors', type=Path,
                    help='tformer_vectors.h: use its tf_features window and '
                         'check the golden against tf_golden_proj')
    ap.add_argument('--header-dir', type=Path,
                    help='write proj_window.h, proj_golden.h, tensor_dim.h')
    ap.add_argument('--verify', action='store_true',
                    help='run onnxruntime and compare against a numpy reference')
    args = ap.parse_args()

    rng = np.random.default_rng(args.seed)
    if args.weights:
        proj = read_c_array(args.weights, 'tf_proj').reshape(FEATURES, D_MODEL)
        pos = read_c_array(args.weights, 'tf_pos').reshape(FRAMES, D_MODEL)
        source = f'weights {args.weights.name}'
    else:
        proj = rng.standard_normal((FEATURES, D_MODEL)).astype(np.float16)
        pos = rng.standard_normal((FRAMES, D_MODEL)).astype(np.float16)
        source = f'seed {args.seed}'
    if args.vectors:
        # The firmware stores the window tile-major, [2][12][16] (the two X
        # operands); the graph input is the row-major [12][32] matrix.
        tiles = read_c_array(args.vectors, 'tf_features').reshape(
            FEATURES // TILE, FRAMES, TILE)
        window = np.concatenate(list(tiles), axis=1)
        source += f', window {args.vectors.name}'
    else:
        window = rng.standard_normal((FRAMES, FEATURES)).astype(np.float16)

    model = build_model(proj, pos)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    onnx.save(model, args.out)
    
    

    golden = redmule_projection(window, proj, pos)
    if args.vectors:
        fw = read_c_array(args.vectors, 'tf_golden_proj').reshape(FRAMES, D_MODEL)
        same = np.array_equal(golden.view(np.uint16), fw.view(np.uint16))
        print(f'golden vs firmware tf_golden_proj: '
              f'{"bit-exact" if same else "DIFFERENT"}')
        if not same:
            raise SystemExit('the RedMulE reference disagrees with tf_golden_proj '
                             '(weights and vectors from different exports?)')
    if args.header_dir:
        write_headers(args.header_dir, window, golden, source)
        print(f'wrote {args.header_dir}/proj_window.h, proj_golden.h, tensor_dim.h')

    if args.verify:
        import onnxruntime as ort
        ref = (window.astype(np.float64) @ proj.astype(np.float64)
               + pos.astype(np.float64))
        sess = ort.InferenceSession(args.out.as_posix(),
                                    providers=['CPUExecutionProvider'])
        got = sess.run(['h'], {'window': window})[0].astype(np.float64)
        max_abs = float(np.max(np.abs(got - ref)))
        red = float(np.max(np.abs(golden.astype(np.float64) - ref)))
        print(f'onnxruntime vs float64 ref: max_abs_diff = {max_abs:.4g}')
        print(f'RedMulE golden vs float64 ref: max_abs_diff = {red:.4g}')
        assert max_abs < 1e-1, 'projection mismatch'
        print('OK')


if __name__ == '__main__':
    main()