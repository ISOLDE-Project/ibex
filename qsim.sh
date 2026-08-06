#!/usr/bin/env bash
# Copyleft

# Define environment variables
MINICONDA=~/miniconda3/etc/profile.d/conda.sh
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

export BENDER=$ROOT_DIR/eda/bender/bin/bender
export SLANG=$ROOT_DIR/eda/slang/bin/slang

module load lic questasim qformal

source $MINICONDA
conda activate $MINICONDA_ENV

#export PATH=~/eth/bin:~/verible/bin:$PATH

