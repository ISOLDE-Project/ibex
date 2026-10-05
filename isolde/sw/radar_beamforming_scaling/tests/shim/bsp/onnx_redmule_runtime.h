/* HOST TEST ONLY. Prototypes inferred from calls in the supplied original
 * runtime; this is NOT the missing production BSP header. Never use on FPGA.
 */
#ifndef BF_TEST_RUNTIME_H
#define BF_TEST_RUNTIME_H
#include <stdint.h>
uint32_t omrm_addr_start(uint32_t, uint32_t);
uint32_t omrm_upload_f16(uint32_t, uint32_t, const void *, uint32_t, uint32_t);
void omrm_zero_f16(uint32_t, uint32_t, uint32_t);
void omrm_gemm_f16_16_12_16(uint32_t, uint32_t, uint32_t, uint32_t);
void omrm_wait(uint32_t);
void omrm_download_f16(uint32_t, uint32_t, void *, uint32_t);
#endif
