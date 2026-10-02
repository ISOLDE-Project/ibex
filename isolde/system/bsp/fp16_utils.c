

#include <bsp/fp16_utils.h>
#include <bsp/tinyprintf.h>

static inline uint16_t ordered_fp16_bits(uint16_t bits)
{
  if ((bits & 0x8000u) != 0u)
    return (uint16_t)(~bits);
  return (uint16_t)(bits | 0x8000u);
}

static inline uint32_t fp16_ulp_distance(uint16_t lhs, uint16_t rhs)
{
  uint16_t ordered_lhs = ordered_fp16_bits(lhs);
  uint16_t ordered_rhs = ordered_fp16_bits(rhs);
  return ordered_lhs >= ordered_rhs
             ? (uint32_t)(ordered_lhs - ordered_rhs)
             : (uint32_t)(ordered_rhs - ordered_lhs);
}


static inline uint16_t load_fp16_bits(const _Float16 *source, uint32_t index)
{
  const fp16_storage_t *bits =
      (const fp16_storage_t *)(const void *)source;
  return bits[index];
}

uint32_t validate_result(const fp16_storage_t *actual,
                                const _Float16 *golden,
                                uint32_t len,
                                uint32_t k_size,
                                const char *name,
                                uint32_t *worst_ulp)
{
  uint32_t errors = 0u;
  uint32_t index;

  for (index = 0u; index < len; ++index) {
    uint16_t expected = load_fp16_bits(golden, index);
    uint32_t ulp = fp16_ulp_distance(actual[index], expected);

    if (ulp > *worst_ulp)
      *worst_ulp = ulp;

    if (ulp > MAX_ULP_ERROR) {
      if (errors < 8u) {
        printf("[ONNX-CGEMM] %s[%d][%d] got=0x%04x expected=0x%04x "
               "ulp=%d\n",
               name, (int)(index / k_size), (int)(index % k_size),
               (unsigned)actual[index], (unsigned)expected, (unsigned)ulp);
      }
      ++errors;
    }
  }

  return errors;
}
