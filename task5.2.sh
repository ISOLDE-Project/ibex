#!/usr/bin/env bash
set -euo pipefail

# Root directory
ROOT_DIR=$(git rev-parse --show-toplevel) || { echo "[ERROR] Not a git repository"; exit 1; }
HIDDEN_DIR="$ROOT_DIR/.task5.2"
CONFIG_FILE="$ROOT_DIR/.task5.2.config"

# Defaults
DEFAULT_REPO_URL="https://github.com/ISOLDE-Project/task5.2.git"
DEFAULT_REF="master"

# Create config file if missing
if [ ! -f "$CONFIG_FILE" ]; then
    cat > "$CONFIG_FILE" <<EOF
REPO_URL=$DEFAULT_REPO_URL
REF=$DEFAULT_REF
EOF
fi

# Read config
source "$CONFIG_FILE"

# Allow REF override via CLI
REF="${1:-$REF}"

# Paths
CHECKOUT_DIR="$HIDDEN_DIR/git/checkouts"
HIDDEN_EDA_DIR="$CHECKOUT_DIR/eda"
EDA_DIR="$ROOT_DIR/eda"

# Ensure directories
mkdir -p "$CHECKOUT_DIR" "$EDA_DIR"

# Clone or update
if [ ! -d "$CHECKOUT_DIR/.git" ]; then
    echo "[INFO] Cloning $REPO_URL..."
    git clone --no-checkout "$REPO_URL" "$CHECKOUT_DIR"
    (cd "$CHECKOUT_DIR" && \
        git fetch --depth 1 origin "$REF" && \
        git checkout "$REF")
else
    echo "[INFO] Updating existing checkout..."
    (cd "$CHECKOUT_DIR" && \
        git fetch --depth 1 origin "$REF" && \
        git checkout "$REF")
fi

(cd "$CHECKOUT_DIR" && \
    git submodule update --init --recursive )
# Build
# echo "[INFO] Building EDA tools..."
# (cd "$CHECKOUT_DIR" && make -f Makefile.eda all)

# # Symlink (remove only the symlink, not the directory)
# [ -L "$EDA_DIR" ] && rm -f "$EDA_DIR"
# ln -s "$HIDDEN_EDA_DIR" "$EDA_DIR"

# echo "[INFO] Symlink created: $EDA_DIR -> $HIDDEN_EDA_DIR"
# echo "[INFO] Done."