#!/usr/bin/env bash
# set -euo pipefail

# Get the root directory of the Git repository
export ROOT_DIR=$(git rev-parse --show-toplevel)
HIDDEN_DIR="$ROOT_DIR/.task5.2"
CHECKOUT_DIR="$HIDDEN_DIR/git/checkouts" 
HIDDEN_ONNX_DIR="$CHECKOUT_DIR/install/onnx-mlir"
ONNX_DIR="$ROOT_DIR/install/onnx-mlir"

REPO_URL="https://github.com/ISOLDE-Project/task5.2.git"
REF="master"   # or a tag/commit hash

mkdir -p "$HIDDEN_DIR/git/checkouts"
mkdir -p "$ONNX_DIR"

if [ ! -d "$CHECKOUT_DIR/.git" ]; then
    echo "[INFO] run . ./eda.sh"
    # git clone --no-checkout "$REPO_URL" "$CHECKOUT_DIR"

    # pushd "$CHECKOUT_DIR" >/dev/null

    # # Fetch only the desired ref
    # git fetch --depth 1 origin "$REF"

    # # Detached HEAD checkout (headless)
    # #git checkout --detach FETCH_HEAD
    # git checkout  FETCH_HEAD

    # popd >/dev/null
else
    echo "[INFO] task5.2 already present"

    # pushd "$CHECKOUT_DIR" >/dev/null

    # git fetch --depth 1 origin "$REF"
    # #git checkout --detach FETCH_HEAD
    # git checkout  FETCH_HEAD

    # popd >/dev/null
fi

#echo "[INFO] Building EDA tools..."

# pushd "$CHECKOUT_DIR" >/dev/null
# make -f Makefile.eda all
# popd >/dev/null

# Create
rm -rf "$ONNX_DIR"
ln -s "$HIDDEN_ONNX_DIR" "$ONNX_DIR"


echo "[INFO] Symlink created:"
echo "       $HIDDEN_EDA_DIR -> $EDA_DIR"

echo "[INFO] Done."