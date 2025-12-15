ROOT_DIR=$(git rev-parse --show-toplevel)
MINICONDA_ENV=ibex

### install miniconda in home folder
cd ~
wget https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh
bash Miniconda3-latest-*.sh
### start miniconda
. ~/miniconda3/etc/profile.d/conda.sh
### setup conda environment
conda create --name $MINICONDA_ENV python=3.10
conda activate $MINICONDA_ENV 
pip3 install -U -r python-requirements.txt
### install bender
cd ~
mkdir -p ~/eth/bin/
cd ~/eth/bin
curl --proto '=https' --tlsv1.2 https://pulp-platform.github.io/bender/init -sSf | sh
cd $ROOT_DIR
. ./qsim.sh 