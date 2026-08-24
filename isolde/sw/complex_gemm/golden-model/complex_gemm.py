#!/usr/bin/env python3
"""Generate FP16 split-complex data for software-tiled RedMulE complex GEMM.

Python matrices use built-in ``complex`` values.  The emitted hardware golden
models the four-real-GEMM schedule:

    Cr += Ar*Br
    Ci += Ar*Bi
    Cr += Ai*(-Bi)
    Ci += Ai*Br

for each reduction tile.  A high-precision Python-complex reference is also
computed and reported for accuracy analysis.
"""

import argparse
import math
import random
from pathlib import Path
from typing import List

import numpy as np

DEFAULT_M, DEFAULT_N, DEFAULT_K = 24, 32, 32
DEFAULT_TILE_M, DEFAULT_TILE_N, DEFAULT_TILE_K = 12, 16, 16
SPM_PAYLOAD_WORDS = 8


def ceil_div(a: int, b: int) -> int:
    return (a + b - 1) // b


def q16(x: float) -> float:
    return float(np.float16(x))


def fp16_fma(a: float, b: float, c: float) -> float:
    return float(np.float16(
        np.float32(np.float16(a)) * np.float32(np.float16(b))
        + np.float32(np.float16(c))
    ))


def validate_dimensions(m, n, k, tm, tn, tk):
    for name, value in (("M", m), ("N", n), ("K", k),
                        ("TILE_M", tm), ("TILE_N", tn), ("TILE_K", tk)):
        if value <= 0:
            raise ValueError(f"{name} must be > 0")
    for name, elems in (("X", tm * tn), ("W", tn * tk), ("Y", tm * tk)):
        if elems % 2:
            raise ValueError(f"{name} tile must contain an even number of FP16 values")
        if (elems // 2) % SPM_PAYLOAD_WORDS:
            raise ValueError(
                f"{name} tile has {elems // 2} uint32 words; current BSP "
                f"requires a multiple of {SPM_PAYLOAD_WORDS}"
            )


def make_complex_matrix(rows: int, cols: int, rng: random.Random) -> List[List[complex]]:
    out = []
    for _ in range(rows):
        row = []
        for _ in range(cols):
            # Python built-in complex numbers; each component is first quantized to FP16.
            row.append(complex(q16(rng.uniform(-1.0, 1.0)),
                               q16(rng.uniform(-1.0, 1.0))))
        out.append(row)
    return out


def python_complex_gemm(a, b):
    m, n, k = len(a), len(a[0]), len(b[0])
    c = [[0j for _ in range(k)] for _ in range(m)]
    for mi in range(m):
        for ki in range(k):
            acc = 0j
            for ni in range(n):
                acc += a[mi][ni] * b[ni][ki]
            c[mi][ki] = acc
    return c


def extract_component_tile(matrix, r0, c0, tr, tc, imag):
    rows, cols = len(matrix), len(matrix[0])
    out = [[0.0 for _ in range(tc)] for _ in range(tr)]
    for r in range(tr):
        for c in range(tc):
            gr, gc = r0 + r, c0 + c
            if gr < rows and gc < cols:
                z = matrix[gr][gc]
                out[r][c] = z.imag if imag else z.real
    return out


def real_gemm_accumulate(x, w, y, negate_w=False):
    tm, tn, tk = len(x), len(x[0]), len(w[0])
    out = [[q16(y[m][k]) for k in range(tk)] for m in range(tm)]
    for m in range(tm):
        for k in range(tk):
            acc = out[m][k]
            for n in range(tn):
                wv = -w[n][k] if negate_w else w[n][k]
                acc = fp16_fma(x[m][n], wv, acc)
            out[m][k] = acc
    return out


def tiled_complex_gemm(a, b, tm, tn, tk):
    m, n, k = len(a), len(a[0]), len(b[0])
    cr = [[0.0 for _ in range(k)] for _ in range(m)]
    ci = [[0.0 for _ in range(k)] for _ in range(m)]

    for m0 in range(0, m, tm):
        for k0 in range(0, k, tk):
            cr_tile = [[0.0 for _ in range(tk)] for _ in range(tm)]
            ci_tile = [[0.0 for _ in range(tk)] for _ in range(tm)]

            for n0 in range(0, n, tn):
                ar = extract_component_tile(a, m0, n0, tm, tn, False)
                ai = extract_component_tile(a, m0, n0, tm, tn, True)
                br = extract_component_tile(b, n0, k0, tn, tk, False)
                bi = extract_component_tile(b, n0, k0, tn, tk, True)

                # Same ordering as complex_gemm.c.
                cr_tile = real_gemm_accumulate(ar, br, cr_tile)
                ci_tile = real_gemm_accumulate(ar, bi, ci_tile)
                cr_tile = real_gemm_accumulate(ai, bi, cr_tile, negate_w=True)
                ci_tile = real_gemm_accumulate(ai, br, ci_tile)

            for mi in range(tm):
                for ki in range(tk):
                    gm, gk = m0 + mi, k0 + ki
                    if gm < m and gk < k:
                        cr[gm][gk] = cr_tile[mi][ki]
                        ci[gm][gk] = ci_tile[mi][ki]
    return cr, ci


def format_fp16(x: float) -> str:
    return repr(float(np.float16(x)))


def emit_fp16_header(path: Path, symbol: str, values, comment: str):
    lines = [
        "/* Auto-generated -- do not edit. */",
        "/* IEEE-754 binary16 data represented as C _Float16. */",
        "", f"/* {comment} */", "",
        f"static const _Float16 {symbol}[{len(values)}] = {{",
    ]
    for i, value in enumerate(values):
        lines.append(f"    {format_fp16(value)}" + ("," if i + 1 != len(values) else ""))
    lines += ["};", ""]
    path.write_text("\n".join(lines))


def flatten_component(matrix, imag):
    return [(z.imag if imag else z.real) for row in matrix for z in row]


def flatten_real(matrix):
    return [x for row in matrix for x in row]


def emit_tensor_dim(path, m, n, k, tm, tn, tk):
    path.write_text(f'''/* Auto-generated -- do not edit. */
/*
    Complex GEMM: C = A @ B
    A: {m} x {n} complex FP16 components
    B: {n} x {k} complex FP16 components
    C: {m} x {k} complex FP16 components

    RedMulE real tile:
    X: {tm} x {tn}
    W: {tn} x {tk}
    Y: {tm} x {tk}
*/
#ifndef __COMPLEX_TENSOR_DIM_H__
#define __COMPLEX_TENSOR_DIM_H__
#define M_SIZE {m}
#define N_SIZE {n}
#define K_SIZE {k}
#define TILE_M_SIZE {tm}
#define TILE_N_SIZE {tn}
#define TILE_K_SIZE {tk}
#define M_TILE_COUNT ((M_SIZE + TILE_M_SIZE - 1) / TILE_M_SIZE)
#define N_TILE_COUNT ((N_SIZE + TILE_N_SIZE - 1) / TILE_N_SIZE)
#define K_TILE_COUNT ((K_SIZE + TILE_K_SIZE - 1) / TILE_K_SIZE)
#define SRC_FMT FP16
#define DST_FMT FP16
#define FPFORMAT 16
#endif
''')


def report_accuracy(py_ref, cr, ci):
    max_abs = 0.0
    sq = 0.0
    count = 0
    for m in range(len(py_ref)):
        for k in range(len(py_ref[0])):
            err = abs(complex(cr[m][k], ci[m][k]) - py_ref[m][k])
            max_abs = max(max_abs, err)
            sq += err * err
            count += 1
    print(f"  vs Python complex reference: max_abs_error={max_abs:.6g}, rms_error={math.sqrt(sq/count):.6g}")


def parse_args():
    p = argparse.ArgumentParser(description="Generate tiled complex GEMM data for RedMulE")
    p.add_argument("--m", type=int, default=DEFAULT_M)
    p.add_argument("--n", type=int, default=DEFAULT_N)
    p.add_argument("--k", type=int, default=DEFAULT_K)
    p.add_argument("--tile-m", type=int, default=DEFAULT_TILE_M)
    p.add_argument("--tile-n", type=int, default=DEFAULT_TILE_N)
    p.add_argument("--tile-k", type=int, default=DEFAULT_TILE_K)
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--out-dir", type=Path, default=Path("../inc"))
    return p.parse_args()


def main():
    a = parse_args()
    validate_dimensions(a.m, a.n, a.k, a.tile_m, a.tile_n, a.tile_k)
    rng = random.Random(a.seed)

    # Source matrices are Python built-in complex values.
    A = make_complex_matrix(a.m, a.n, rng)
    B = make_complex_matrix(a.n, a.k, rng)

    py_ref = python_complex_gemm(A, B)
    cr, ci = tiled_complex_gemm(A, B, a.tile_m, a.tile_n, a.tile_k)

    a.out_dir.mkdir(parents=True, exist_ok=True)
    emit_tensor_dim(a.out_dir / "tensor_dim.h", a.m, a.n, a.k,
                    a.tile_m, a.tile_n, a.tile_k)
    emit_fp16_header(a.out_dir / "ar_input.h", "ar_inp", flatten_component(A, False),
                     f"real(A), shape ({a.m}, {a.n})")
    emit_fp16_header(a.out_dir / "ai_input.h", "ai_inp", flatten_component(A, True),
                     f"imag(A), shape ({a.m}, {a.n})")
    emit_fp16_header(a.out_dir / "br_input.h", "br_inp", flatten_component(B, False),
                     f"real(B), shape ({a.n}, {a.k})")
    emit_fp16_header(a.out_dir / "bi_input.h", "bi_inp", flatten_component(B, True),
                     f"imag(B), shape ({a.n}, {a.k})")
    emit_fp16_header(a.out_dir / "cr_golden.h", "cr_golden", flatten_real(cr),
                     f"real(C), tiled FP16 golden, shape ({a.m}, {a.k})")
    emit_fp16_header(a.out_dir / "ci_golden.h", "ci_golden", flatten_real(ci),
                     f"imag(C), tiled FP16 golden, shape ({a.m}, {a.k})")

    print("Generated complex GEMM:")
    print(f"  A            : {a.m} x {a.n}")
    print(f"  B            : {a.n} x {a.k}")
    print(f"  C            : {a.m} x {a.k}")
    print(f"  RedMulE tile : {a.tile_m}x{a.tile_n} @ {a.tile_n}x{a.tile_k}")
    print(f"  tile grid    : {ceil_div(a.m,a.tile_m)} x {ceil_div(a.k,a.tile_k)}, "
          f"{ceil_div(a.n,a.tile_n)} reduction chunks")
    print(f"  seed         : {a.seed}")
    report_accuracy(py_ref, cr, ci)
    print(f"  output       : {a.out_dir.resolve()}")


if __name__ == "__main__":
    main()
