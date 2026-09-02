#!/usr/bin/env bash
# Copyleft

# Define environment variables
MINICONDA=$HOME/hdd1/miniconda3/etc/profile.d/conda.sh
MINICONDA_ENV=ibex
# To activate this environment, use
#
#     $ conda activate ibex
#
# To deactivate an active environment, use
#
#     $ conda deactivate

# Get the root directory of the Git repository
export ROOT_DIR=$(git rev-parse --show-toplevel)

export     BENDER=$ROOT_DIR/eda/bender/bin/bender
export      SLANG=$ROOT_DIR/eda/oss-cad-suite/bin/slang
export      YOSYS=$ROOT_DIR/eda/oss-cad-suite/bin/yosys
export  VERILATOR=$ROOT_DIR/eda/verilator/bin/verilator
export    OPENOCD=$ROOT_DIR/eda/oss-cad-suite/bin/openocd
# export OPENROAD=$ROOT_DIR/install/openroad/usr/local/bin/openroad
# export PULP_RISCV_GCC_TOOLCHAIN=$ROOT_DIR/install/riscv
# export GCC_TOOLCHAIN=$ROOT_DIR/install/riscv-gcc/bin
# export LLVM_TOOLCHAIN=$ROOT_DIR/install/riscv-llvm/bin
# export CC=clang
# export CXX=clang++
#
# export CV_SIMULATOR=verilator
# export CV_SW_TOOLCHAIN=$ROOT_DIR/install/riscv-gcc
# export CV_SW_PREFIX=riscv32-unknown-elf-
# export CV_SW_MARCH=rv32im_zicsr
# export CV_SW_CC=gcc


source $MINICONDA
conda activate $MINICONDA_ENV

# export PATH=$ROOT_DIR/eda/oss-cad-suite/bin:$PATH
source ~/vivado.sh

echo  `$VERILATOR --version`