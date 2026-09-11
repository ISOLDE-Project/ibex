# THIS IS A GENERATED FILE - DO NOT EDIT.
# Source: isolde/config/platform.yml, template isolde/templates/platform.mk.j2,
# platform 'demo_3'.
#
# Memory map and tile count for the software build. Included by
# isolde/mk/sw-build.mk and sourced by isolde/system/fragment_hex.sh, so the
# image-split addresses come from the same place as link.ld and the RTL
# packages instead of being retyped.

PLATFORM_NAME   := demo_3
N_TILES         := 3

INSTRRAM_ORIGIN := 0x00100000
INSTRRAM_LENGTH := 0x8000
INSTRRAM_LAST   := 0x00107fff
DATARAM_ORIGIN  := 0x00110000
DATARAM_LENGTH  := 0x8000
DATARAM_LAST    := 0x00117fff
STACK_ORIGIN    := 0x00140000
STACK_LENGTH    := 0x4000
STACK_LAST      := 0x00143fff

# Inclusive [start end] bounds for hex_fragment.py, which trims the emitted
# image down to the last non-zero byte inside the window. Bounds are the
# region's own extent: link.ld binds each section with "> instrram" /
# "> dataram", so GNU ld already errors if a section outgrows its region.
IMAGE_INSTR_RANGE := $(INSTRRAM_ORIGIN) $(INSTRRAM_LAST)
IMAGE_DATA_RANGE  := $(DATARAM_ORIGIN) $(DATARAM_LAST)
