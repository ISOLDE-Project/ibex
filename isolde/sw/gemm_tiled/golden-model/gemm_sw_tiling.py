#!/usr/bin/env python3
"""
Generate FP16 test data for the ISOLDE/RedMulE software-tiled GEMM test.

RedMulE notation
----------------
    Z[M x K] = Y[M x K] + X[M x N] @ W[N x K]

The software test executes the same operation as a sequence of fixed-size
RedMulE jobs:

    X tile: TILE_M x TILE_N
    W tile: TILE_N x TILE_K
    Y tile: TILE_M x TILE_K

The output matrix is tiled over M and K.  N is the reduction dimension.
Boundary tiles are zero padded so every RedMulE launch keeps the same
compile-time dimensions.

By default the golden model emulates an FP16 fused multiply-add chain and
stores the accumulator back to FP16 after every FMA.  This is deterministic
and models the software-visible tiled accumulation order.  The exact internal
reduction order of a particular RedMulE RTL configuration can differ, so the
C test should normally use the same tolerance policy as the existing
omp_test rather than requiring bit-exact equality.
"""

import argparse
from pathlib import Path
from typing import Iterable

import numpy as np


DEFAULT_M = 24
DEFAULT_N = 32
DEFAULT_K = 32

DEFAULT_TILE_M = 12
DEFAULT_TILE_N = 16
DEFAULT_TILE_K = 16

SPM_PAYLOAD_WORDS = 8  # NUM_BANKS - 1 in the current ISOLDE BSP.


def ceil_div(a: int, b: int) -> int:
    return (a + b - 1) // b


def validate_dimensions(
    m: int,
    n: int,
    k: int,
    tile_m: int,
    tile_n: int,
    tile_k: int,
) -> None:
    for name, value in (
        ("M", m),
        ("N", n),
        ("K", k),
        ("TILE_M", tile_m),
        ("TILE_N", tile_n),
        ("TILE_K", tile_k),
    ):
        if value <= 0:
            raise ValueError(f"{name} must be > 0, got {value}")

    # spm_write()/spm_read() consume uint32_t elements and currently transfer
    # only complete payload rows of NUM_BANKS - 1 = 8 words.  Two FP16 values
    # occupy one uint32_t word, hence every operand tile must contain a
    # multiple of 16 FP16 values.
    tile_shapes = {
        "X": tile_m * tile_n,
        "W": tile_n * tile_k,
        "Y/Z": tile_m * tile_k,
    }

    for name, fp16_elems in tile_shapes.items():
        if fp16_elems % 2:
            raise ValueError(
                f"{name} tile has {fp16_elems} FP16 elements; "
                "the size must be even"
            )

        words = fp16_elems // 2
        if words % SPM_PAYLOAD_WORDS:
            raise ValueError(
                f"{name} tile has {words} uint32_t words; "
                f"it must be a multiple of {SPM_PAYLOAD_WORDS} "
                "for the current BSP SPM transfer routines"
            )


def fp16_fma(a: np.float16, b: np.float16, c: np.float16) -> np.float16:
    """
    Emulate one binary16 fused multiply-add.

    FP32 is sufficient to hold the exact product of two FP16 significands and
    the addition with an FP16 accumulator before the final conversion back to
    FP16.  The final np.float16 cast provides the binary16 rounding step.
    """
    return np.float16(
        np.float32(a) * np.float32(b) + np.float32(c)
    )


def redmule_tile_reference(
    x_tile: np.ndarray,
    w_tile: np.ndarray,
    y_tile: np.ndarray,
) -> np.ndarray:
    """
    Reference for one fixed-size RedMulE GEMM job:

        Z = Y + X @ W

    All operands and the accumulator are binary16.
    """
    tile_m, tile_n = x_tile.shape
    w_n, tile_k = w_tile.shape

    if w_n != tile_n:
        raise ValueError("X/W tile reduction dimensions do not match")
    if y_tile.shape != (tile_m, tile_k):
        raise ValueError("Y tile shape does not match X/W output shape")

    z = np.array(y_tile, dtype=np.float16, copy=True)

    for mi in range(tile_m):
        for ki in range(tile_k):
            acc = np.float16(z[mi, ki])
            for ni in range(tile_n):
                acc = fp16_fma(
                    np.float16(x_tile[mi, ni]),
                    np.float16(w_tile[ni, ki]),
                    acc,
                )
            z[mi, ki] = acc

    return z


def extract_x_tile(
    x: np.ndarray,
    m0: int,
    n0: int,
    tile_m: int,
    tile_n: int,
) -> np.ndarray:
    tile = np.zeros((tile_m, tile_n), dtype=np.float16)

    m_valid = min(tile_m, x.shape[0] - m0)
    n_valid = min(tile_n, x.shape[1] - n0)

    if m_valid > 0 and n_valid > 0:
        tile[:m_valid, :n_valid] = x[
            m0 : m0 + m_valid,
            n0 : n0 + n_valid,
        ]

    return tile


def extract_w_tile(
    w: np.ndarray,
    n0: int,
    k0: int,
    tile_n: int,
    tile_k: int,
) -> np.ndarray:
    tile = np.zeros((tile_n, tile_k), dtype=np.float16)

    n_valid = min(tile_n, w.shape[0] - n0)
    k_valid = min(tile_k, w.shape[1] - k0)

    if n_valid > 0 and k_valid > 0:
        tile[:n_valid, :k_valid] = w[
            n0 : n0 + n_valid,
            k0 : k0 + k_valid,
        ]

    return tile


def extract_y_tile(
    y: np.ndarray,
    m0: int,
    k0: int,
    tile_m: int,
    tile_k: int,
) -> np.ndarray:
    tile = np.zeros((tile_m, tile_k), dtype=np.float16)

    m_valid = min(tile_m, y.shape[0] - m0)
    k_valid = min(tile_k, y.shape[1] - k0)

    if m_valid > 0 and k_valid > 0:
        tile[:m_valid, :k_valid] = y[
            m0 : m0 + m_valid,
            k0 : k0 + k_valid,
        ]

    return tile


def store_z_tile(
    z: np.ndarray,
    z_tile: np.ndarray,
    m0: int,
    k0: int,
) -> None:
    m_valid = min(z_tile.shape[0], z.shape[0] - m0)
    k_valid = min(z_tile.shape[1], z.shape[1] - k0)

    if m_valid > 0 and k_valid > 0:
        z[
            m0 : m0 + m_valid,
            k0 : k0 + k_valid,
        ] = z_tile[:m_valid, :k_valid]


def sw_tiled_gemm_reference(
    x: np.ndarray,
    w: np.ndarray,
    y: np.ndarray,
    tile_m: int,
    tile_n: int,
    tile_k: int,
) -> np.ndarray:
    """
    Model the sequence executed by gemm_tiled.c.

    Output tiles are independent.  For each output tile, Y is loaded once and
    remains the accumulator across all N/reduction chunks.
    """
    m, n = x.shape
    w_n, k = w.shape

    if w_n != n:
        raise ValueError("X and W reduction dimensions do not match")
    if y.shape != (m, k):
        raise ValueError("Y has an invalid shape")

    z = np.empty((m, k), dtype=np.float16)

    for m0 in range(0, m, tile_m):
        for k0 in range(0, k, tile_k):
            z_tile = extract_y_tile(
                y, m0, k0, tile_m, tile_k
            )

            for n0 in range(0, n, tile_n):
                x_tile = extract_x_tile(
                    x, m0, n0, tile_m, tile_n
                )
                w_tile = extract_w_tile(
                    w, n0, k0, tile_n, tile_k
                )

                # This corresponds to one redmule_gemm_async() launch.
                z_tile = redmule_tile_reference(
                    x_tile, w_tile, z_tile
                )

            store_z_tile(z, z_tile, m0, k0)

    return z


def format_fp16(value: np.float16) -> str:
    # Conversion through Python float gives a compact decimal string that
    # round-trips to the same binary16 value when compiled as _Float16.
    return repr(float(np.float16(value)))


def emit_fp16_header(
    path: Path,
    symbol: str,
    matrix: np.ndarray,
    shape_comment: str,
) -> None:
    flat = np.asarray(matrix, dtype=np.float16).reshape(-1)

    lines = [
        "/* Auto-generated -- do not edit. */",
        "/* IEEE-754 binary16 data represented as C _Float16. */",
        "",
        f"/* {shape_comment} */",
        "",
        f"static const _Float16 {symbol}[{flat.size}] = {{",
    ]

    for i, value in enumerate(flat):
        comma = "," if i + 1 != flat.size else ""
        lines.append(f"    {format_fp16(value)}{comma}")

    lines.append("};")
    lines.append("")

    path.write_text("\n".join(lines))


def emit_tensor_dim_header(
    path: Path,
    m: int,
    n: int,
    k: int,
    tile_m: int,
    tile_n: int,
    tile_k: int,
) -> None:
    text = f"""/* Auto-generated -- do not edit. */
/*
    Full operation:
        Z = Y + X @ W

        X: {m} x {n}
        W: {n} x {k}
        Y: {m} x {k}
        Z: {m} x {k}

    Software/RedMulE tile:
        X: {tile_m} x {tile_n}
        W: {tile_n} x {tile_k}
        Y: {tile_m} x {tile_k}
        Z: {tile_m} x {tile_k}
*/

#ifndef __TENSOR_DIM__
#define __TENSOR_DIM__

/* Full RedMulE problem dimensions. */
#define M_SIZE {m}
#define N_SIZE {n}
#define K_SIZE {k}

/* Fixed dimensions encoded in every RedMulE launch. */
#define TILE_M_SIZE {tile_m}
#define TILE_N_SIZE {tile_n}
#define TILE_K_SIZE {tile_k}

#define M_TILE_COUNT ((M_SIZE + TILE_M_SIZE - 1) / TILE_M_SIZE)
#define N_TILE_COUNT ((N_SIZE + TILE_N_SIZE - 1) / TILE_N_SIZE)
#define K_TILE_COUNT ((K_SIZE + TILE_K_SIZE - 1) / TILE_K_SIZE)

#define SRC_FMT FP16
#define DST_FMT FP16
#define FPFORMAT 16

#endif
"""
    path.write_text(text)


def generate_inputs(
    m: int,
    n: int,
    k: int,
    seed: int,
    zero_y: bool,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    rng = np.random.default_rng(seed)

    # Quantize inputs to FP16 before computing the reference, matching the
    # representation used in the generated C headers.
    x = rng.random((m, n), dtype=np.float32).astype(np.float16)
    w = rng.random((n, k), dtype=np.float32).astype(np.float16)

    if zero_y:
        y = np.zeros((m, k), dtype=np.float16)
    else:
        y = rng.random((m, k), dtype=np.float32).astype(np.float16)

    return x, w, y


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate FP16 data for the RedMulE SW-tiling GEMM test"
    )

    # M/N/K intentionally follow RedMulE's naming convention.
    parser.add_argument("--m", type=int, default=DEFAULT_M,
                        help="rows of X/Y/Z (default: %(default)s)")
    parser.add_argument("--n", type=int, default=DEFAULT_N,
                        help="reduction dimension, columns of X / rows of W "
                             "(default: %(default)s)")
    parser.add_argument("--k", type=int, default=DEFAULT_K,
                        help="columns of W/Y/Z (default: %(default)s)")

    parser.add_argument("--tile-m", type=int, default=DEFAULT_TILE_M,
                        help="RedMulE tile M (default: %(default)s)")
    parser.add_argument("--tile-n", type=int, default=DEFAULT_TILE_N,
                        help="RedMulE tile N / reduction tile "
                             "(default: %(default)s)")
    parser.add_argument("--tile-k", type=int, default=DEFAULT_TILE_K,
                        help="RedMulE tile K (default: %(default)s)")

    parser.add_argument("--seed", type=int, default=1,
                        help="random seed (default: %(default)s)")
    parser.add_argument("--zero-y", action="store_true",
                        help="generate Y as all zeros instead of random FP16")
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=Path("."),
        help="directory for tensor_dim.h/x_input.h/w_input.h/"
             "y_input.h/golden.h",
    )

    return parser.parse_args()


def main() -> None:
    args = parse_args()

    validate_dimensions(
        args.m,
        args.n,
        args.k,
        args.tile_m,
        args.tile_n,
        args.tile_k,
    )

    args.out_dir.mkdir(parents=True, exist_ok=True)

    x, w, y = generate_inputs(
        args.m,
        args.n,
        args.k,
        args.seed,
        args.zero_y,
    )

    golden = sw_tiled_gemm_reference(
        x,
        w,
        y,
        args.tile_m,
        args.tile_n,
        args.tile_k,
    )

    emit_tensor_dim_header(
        args.out_dir / "tensor_dim.h",
        args.m,
        args.n,
        args.k,
        args.tile_m,
        args.tile_n,
        args.tile_k,
    )

    emit_fp16_header(
        args.out_dir / "x_input.h",
        "x_inp",
        x,
        f"x_inp ({args.m}, {args.n})",
    )
    emit_fp16_header(
        args.out_dir / "w_input.h",
        "w_inp",
        w,
        f"w_inp ({args.n}, {args.k})",
    )
    emit_fp16_header(
        args.out_dir / "y_input.h",
        "y_inp",
        y,
        f"y_inp ({args.m}, {args.k})",
    )
    emit_fp16_header(
        args.out_dir / "golden.h",
        "golden",
        golden,
        f"golden ({args.m}, {args.k})",
    )

    print("Generated software-tiled RedMulE GEMM test:")
    print(f"  X       : {args.m} x {args.n}")
    print(f"  W       : {args.n} x {args.k}")
    print(f"  Y/Z     : {args.m} x {args.k}")
    print(
        "  HW tile : "
        f"{args.tile_m} x {args.tile_n} @ "
        f"{args.tile_n} x {args.tile_k}"
    )
    print(
        "  SW grid : "
        f"{ceil_div(args.m, args.tile_m)} M tiles x "
        f"{ceil_div(args.k, args.tile_k)} K tiles, "
        f"{ceil_div(args.n, args.tile_n)} reduction chunks"
    )
    print(f"  seed    : {args.seed}")
    print(f"  output  : {args.out_dir.resolve()}")


if __name__ == "__main__":
    main()
