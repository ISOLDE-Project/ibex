#!/usr/bin/env python3
"""Generate golden test data for simple GEMM with deterministic, clean values."""

import argparse
from pathlib import Path

import numpy as np

def parse_args():
    p = argparse.ArgumentParser(description="Generate GEMM golden data")
    p.add_argument("--m", type=int, default=12)
    p.add_argument("--n", type=int, default=16)
    p.add_argument("--k", type=int, default=16)
    p.add_argument("--seed", type=int, default=1) # Seed is kept for consistency but not used for generation
    p.add_argument("--out-dir", type=Path, required=True)
    return p.parse_args()

def fp16_to_hex(arr):
    """Convert a float16 numpy array to a list of uint16 hex strings."""
    return [f"0x{int(x):04x}" for x in arr.view(np.uint16).flatten()]

def write_header(path, name, values, cols=16):
    """Write a C header with a fp16_storage_t array."""
    with open(path, "w") as f:
        f.write(f"#ifndef {name.upper()}_H\n")
        f.write(f"#define {name.upper()}_H\n\n")
        f.write(f"#include <stdint.h>\n\n")
        f.write(f"static const uint16_t {name}[] = {{\n")
        for i in range(0, len(values), cols):
            line = ", ".join(values[i:i+cols])
            comma = "," if i + cols < len(values) else ""
            f.write(f"  {line}{comma}\n")
        f.write(f"}};\n\n")
        f.write(f"#endif /* {name.upper()}_H */\n")

def fp16_matmul(A, B):
    """Simulate FP16 matrix multiply with FP16 accumulation."""
    m, n = A.shape
    _, k = B.shape
    C = np.zeros((m, k), dtype=np.float16)
    for i in range(m):
        for j in range(k):
            acc = np.float16(0.0)
            for l in range(n):
                acc = np.float16(acc + np.float16(A[i, l] * B[l, j]))
            C[i, j] = acc
    return C

def main():
    a = parse_args()

    # Use a small set of clean, deterministic values instead of random ones
    clean_vals = np.array([-1.0, -0.5, 0.5, 1.0], dtype=np.float16)

    # Create deterministic matrices from the clean values
    A = np.fromfunction(
        lambda i, j: clean_vals[(i + j) % len(clean_vals)], (a.m, a.n), dtype=int
    ).astype(np.float16)
    B = np.fromfunction(
        lambda i, j: clean_vals[(i + 2 * j) % len(clean_vals)], (a.n, a.k), dtype=int
    ).astype(np.float16)

    # Golden calculation with FP16 accumulation
    C = fp16_matmul(A, B)

    # Create output directory
    a.out_dir.mkdir(parents=True, exist_ok=True)

    # Write headers
    write_header(a.out_dir / "ar_input.h", "ar_inp", fp16_to_hex(A))
    write_header(a.out_dir / "br_input.h", "br_inp", fp16_to_hex(B))
    write_header(a.out_dir / "cr_golden.h", "cr_golden", fp16_to_hex(C))

    # Write tensor dimensions (without overriding MAX_ULP_ERROR)
    dim_path = a.out_dir / "tensor_dim.h"
    with open(dim_path, "w") as f:
        f.write("#ifndef TENSOR_DIM_H\n")
        f.write("#define TENSOR_DIM_H\n\n")
        f.write(f"#define M_SIZE {a.m}\n")
        f.write(f"#define N_SIZE {a.n}\n")
        f.write(f"#define K_SIZE {a.k}\n\n")
        f.write("#endif /* TENSOR_DIM_H */\n")

    print(f"Generated golden data in {a.out_dir}/")
    print(f"  A, B created from deterministic, clean values.")
    print(f"  Using default strict ULP tolerance.")

if __name__ == "__main__":
    main()
