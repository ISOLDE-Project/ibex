/* SPDX-License-Identifier: Apache-2.0 */
#ifndef BEAMFORM_RUNTIME_H
#define BEAMFORM_RUNTIME_H
#include <stdint.h>

/* Fixed ABI: A[36][16], B[16][16], C[36][16], split binary16 row-major.
 * Caller owns all buffers and must provide at least three RedMulE tiles.
 * All transfers use the existing BSP; this routine performs no CPU FP math.
 */
void beamform_runtime3(const uint16_t *ar, const uint16_t *ai,
                       const uint16_t *br, const uint16_t *bi,
                       uint16_t *cr, uint16_t *ci);
#endif
