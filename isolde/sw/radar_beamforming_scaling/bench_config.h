/* SPDX-License-Identifier: Apache-2.0 */
#ifndef BF_BENCH_CONFIG_H
#define BF_BENCH_CONFIG_H
/* Edit here, or supply -DBF_BENCH_REPEATS=... through your BSP CFLAGS. */
#ifndef BF_BENCH_REPEATS
#define BF_BENCH_REPEATS 5
#endif
#ifndef BF_BENCH_WARMUPS
#define BF_BENCH_WARMUPS 1
#endif
#if BF_BENCH_REPEATS < 1 || BF_BENCH_REPEATS > 10000
#error "BF_BENCH_REPEATS must be in 1..10000"
#endif
#if BF_BENCH_WARMUPS < 0 || BF_BENCH_WARMUPS > 10000
#error "BF_BENCH_WARMUPS must be in 0..10000"
#endif
#endif
