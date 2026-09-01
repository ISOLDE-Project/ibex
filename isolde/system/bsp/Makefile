CV_SW_TOOLCHAIN  ?= /opt/riscv
RISCV_EXE_PREFIX =  $(CV_SW_TOOLCHAIN)/bin/$(RISCV_PREFIX)
RISCV_CC         =  $(RISCV_EXE_PREFIX)$(RISCV_CC_SUFFIX)
RISCV_LD         =  $(RISCV_EXE_PREFIX)$(RISCV_CC_SUFFIX)
RISCV_AR         =  $(RISCV_EXE_PREFIX)ar
#always use GNU binutils
OBJDUMP          =  $(CV_SW_TOOLCHAIN)/bin/llvm-objdump  

LD_FILE ?=
# Source files
APP_FILES ?=
SRCS   += crt0.S simple_system_common.c startup.c tinyprintf.c 
SRCS   += onnx_redmule_runtime.c
SRCS   += fp16_utils.c spm_load.c
SRCS   += $(APP_FILES)

SRC_C = $(filter %.c, $(SRCS))
SRC_S = $(filter %.S, $(SRCS))
SRC_LL = $(filter %.ll, $(SRCS))

# Generate object files automatically from source files
OBJS += $(SRC_S:.S=.o)
OBJS += $(SRC_C:.c=.o)
OBJS += $(SRC_LL:.ll=.o)

DEPS = $(OBJS:.o=.d)


# Flags for tinyprintf
TINY_PRINTF_FLAGS += -DTINYPRINTF_DEFINE_TFP_PRINTF=1
TINY_PRINTF_FLAGS += -DTINYPRINTF_DEFINE_TFP_SPRINTF=0

# Compiler flags
# Size-first default for the 16 KiB IMEM. After a clean rebuild, override with
# OPT_LEVEL=-Oz or OPT_LEVEL=-O3 to compare image size and runtime.
OPT_LEVEL ?= -O3
# LTO remains opt-in because support depends on the selected compiler/linker.
ENABLE_LTO ?= 0

ifeq ($(ENABLE_LTO),1)
LTO_FLAGS := -flto
endif

CFLAGS ?= -march=$(RISCV_MARCH) -mabi=ilp32 -mcmodel=medany -Wall -g \
	$(OPT_LEVEL) $(LTO_FLAGS) -ffunction-sections -fdata-sections \
	-fvisibility=hidden -ffreestanding $(RISCV_CFLAGS)
CPPFLAGS += $(TINY_PRINTF_FLAGS) $(RISCV_CPPFLAGS)
DEPFLAGS = -MMD -MP -MF $(@:.o=.d) -MT $@
LDFLAGS += $(LTO_FLAGS) -static -nostdlib -nostartfiles -Wl,--gc-sections


# Compilation rules
%.o : %.c
	$(RISCV_CC) $(CPPFLAGS) $(CFLAGS) $(DEPFLAGS) -c $< -o $@

%.o : %.S
	$(RISCV_CC) $(CPPFLAGS) $(CFLAGS) $(DEPFLAGS) -c $< -o $@

# LLVM IR is already preprocessed, so passing -I/-D options is both unnecessary
# and diagnosed by Clang as unused.
%.o : %.ll
	$(RISCV_CC) $(CFLAGS) -c $< -o $@

# Clean up the generated files
clean:
	rm -f $(OBJS) 
	rm -f $(DEPS)  
	rm -f $(LIBCV-VERIF)

# Print variables for debugging
vars:
	@echo "## make bsp variables:"
	@echo "   ############################"
	@echo "   CV_SW_TOOLCHAIN  = $(CV_SW_TOOLCHAIN)"       
	@echo "   RISCV_EXE_PREFIX = $(RISCV_EXE_PREFIX)"
	@echo "   RISCV_CC        = $(RISCV_CC)"
	@echo "   RISCV_MARCH      = $(RISCV_MARCH)"    
	@echo "   OPT_LEVEL        = $(OPT_LEVEL)"
	@echo "   ENABLE_LTO       = $(ENABLE_LTO)"


%.elf:  vars $(OBJS)
#	mkdir -p $(SIM_TEST_PROGRAM_RESULTS)
	@echo "*** linking $(OBJS) into $@"
	@echo "$(BANNER)"
	$(RISCV_LD) \
		$(CFLAGS) \
		$(LDFLAGS) \
		-o $@ \
		$(OBJS) \
		-fuse-ld=lld \
		-Wl,-Map=$@.map \
		-T $(LD_FILE) -lc
	$(OBJDUMP) -dh  $@ >$@.headers
	@echo   $@.headers

-include $(DEPS)
