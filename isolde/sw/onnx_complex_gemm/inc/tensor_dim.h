/* Auto-generated -- do not edit. */
/*
    Complex GEMM: C = A @ B
    A: 12 x 16 complex FP16 components
    B: 16 x 16 complex FP16 components
    C: 12 x 16 complex FP16 components

    RedMulE real tile:
    X: 12 x 16
    W: 16 x 16
    Y: 12 x 16
*/
#ifndef __COMPLEX_TENSOR_DIM_H__
#define __COMPLEX_TENSOR_DIM_H__
#define M_SIZE 12
#define N_SIZE 16
#define K_SIZE 16
#define TILE_M_SIZE 12
#define TILE_N_SIZE 16
#define TILE_K_SIZE 16
#define M_TILE_COUNT ((M_SIZE + TILE_M_SIZE - 1) / TILE_M_SIZE)
#define N_TILE_COUNT ((N_SIZE + TILE_N_SIZE - 1) / TILE_N_SIZE)
#define K_TILE_COUNT ((K_SIZE + TILE_K_SIZE - 1) / TILE_K_SIZE)
#define SRC_FMT FP16
#define DST_FMT FP16
#define FPFORMAT 16
#endif
