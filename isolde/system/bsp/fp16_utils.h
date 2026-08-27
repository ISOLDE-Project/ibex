#ifndef FP16_UTILS_H
#define FP16_UTILS_H

#include <stdint.h>

#define MAX_ULP_ERROR 4u

typedef uint16_t fp16_storage_t __attribute__((may_alias));

uint32_t validate_result(const fp16_storage_t *actual,
                                const _Float16 *golden,
                                uint32_t len,             //number of elements in golden
                                uint32_t k_size,
                                const char *name,
                                uint32_t *worst_ulp);

#endif