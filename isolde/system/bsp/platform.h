/* THIS IS A GENERATED FILE - DO NOT EDIT.
 * Source: isolde/config/platform.yml, template isolde/templates/platform.h.j2,
 * platform 'demo_3'.
 *
 * Memory map and tile count for C code: the same values as link.ld,
 * platform.mk and the RTL packages. Included by bsp/simple_system_regs.h.
 */
#ifndef ISOLDE_PLATFORM_H
#define ISOLDE_PLATFORM_H

#define PLATFORM_NAME             "demo_3"
#define PLATFORM_N_TILES          3u

#define PLATFORM_INSTRRAM_ORIGIN  0x00100000u
#define PLATFORM_INSTRRAM_LENGTH  0x8000u
#define PLATFORM_DATARAM_ORIGIN   0x00110000u
#define PLATFORM_DATARAM_LENGTH   0x8000u
#define PLATFORM_STACK_ORIGIN     0x00140000u
#define PLATFORM_STACK_LENGTH     0x4000u

/* Reset vector: instrram origin + boot_offset (aida_pkg's RV_BOOT_ADDR). */
#define PLATFORM_BOOT_ADDR        0x00100080u

/* Scratchpad window: one tile at a time, chosen with CSR_ISOLDE_TILESEL. */
#define PLATFORM_SPM_NARROW_ADDR  0x80001000u
#define PLATFORM_SPM_NARROW_SIZE  0x8000u

#endif /* ISOLDE_PLATFORM_H */
