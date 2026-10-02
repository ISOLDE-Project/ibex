/*
 *
 * Copyleft 2025 ISOLDE
 *
 */

#ifndef __SCP_H__
#define __SCP_H__

#include <stdint.h>

#define WORD_ALIGN_MASK 0x3
#define BANK_MASK 0x3C  // Bits [5:2]
#define BANK_SHIFT 2
#define BANK_OFFSET_SHIFT 6  // Bits [31:6]

static const uint32_t NUM_BANKS = 9;
static const uint32_t BANK_DATA_WIDTH = 32;
static const uint32_t WIDE_ADDR_ALIGNMENT =
    (NUM_BANKS - 1) * (BANK_DATA_WIDTH / 4);




#endif