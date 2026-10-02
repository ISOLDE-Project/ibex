#!/usr/bin/env bash
# set -euo pipefail

# Get the root directory of the Git repository
export ROOT_DIR=$(git rev-parse --show-toplevel)
HIDDEN_DIR="$ROOT_DIR/.task5.2"
CHECKOUT_DIR="$HIDDEN_DIR/git/checkouts"
HIDDEN_INSTALL_DIR="$CHECKOUT_DIR/install/onnx-mlir"
INSTALL_DIR="$ROOT_DIR/install/onnx-mlir"

REPO_URL="https://github.com/ISOLDE-Project/task5.2.git"
REF="master"   # or a tag/commit hash

mkdir -p "$CHECKOUT_DIR"
# mkdir -p "$EDA_DIR"

if [ ! -d "$CHECKOUT_DIR/.git" ]; then
    echo "[INFO] Cloning task5.2..."
    git clone --no-checkout "$REPO_URL" "$CHECKOUT_DIR"

    pushd "$CHECKOUT_DIR" >/dev/null

    # Fetch only the desired ref
    git fetch --depth 1 origin "$REF"

    # Detached HEAD checkout (headless)
    #git checkout --detach FETCH_HEAD
    git checkout  FETCH_HEAD

    popd >/dev/null

fi

echo "[INFO] Building onnx-mlir ..."

pushd "$CHECKOUT_DIR" >/dev/null
echo install cmake
make toolchain-cmake
echo install mlir
git submodule update --init --recursive toolchain/riscv-llvm
make toolchain-llvm-main
echo install protoc
git submodule update --init --recursive toolchain/protobuf
make toolchain-protoc
echo install onnx-mlir
git submodule update --init --recursive toolchain/onnx-mlir
source  ./eth.sh && make toolchain-onnx-mlir
popd >/dev/null

# Create
# rm -rf "$EDA_DIR"
ln -s "$HIDDEN_INSTALL_DIR" "$INSTALL_DIR"


echo "[INFO] Symlink created:"
echo "$HIDDEN_INSTALL_DIR" "$INSTALL_DIR"

# echo "[INFO] Done."