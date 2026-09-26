#!/usr/bin/env bash
# Build firmware applications serially: the BSP build directory is shared.
set -euo pipefail
export LC_ALL=C
shopt -s nullglob
SYSTEM_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
SW_DIR=$(cd -- "$SYSTEM_DIR/../sw" && pwd -P)
BIN_DIR="$SYSTEM_DIR/sw/bin"
MAKE_BIN=${MAKE_BIN:-make}

usage() {
    cat <<'HELP'
Usage: ./build_apps.sh [--list] [MAKE_VARIABLE=value ...]

Build every firmware app in ../sw, or select names with APPS="hello_test omp_test".
APP_PATH defaults to ./app-images (relative paths are relative to isolde/system).
Successful builds export <app>-*.ihex; logs and summary.tsv are kept there too.
Existing exports for each selected app are removed before its build, so failed
builds cannot leave stale images in the collection. Unselected apps are retained.

Examples:
  ./build_apps.sh --list
  ./build_apps.sh DBG_MODULE=1 ENABLE_SPM=1
  APP_PATH=/tmp/ibex-images APPS="hello_test radar_attention" ./build_apps.sh

Activate your usual ISOLDE/Conda tool environment first. Generated headers and
ONNX graphs must already exist; this script does not train or regenerate models.
Failures are reported after all selected apps have been attempted; exit status
is nonzero if any clean/build/copy step fails. Do not run another firmware build
concurrently: the underlying build uses shared BSP and source-directory objects.
HELP
}

list_only=0
make_vars=()
for arg in "$@"; do
    case "$arg" in
        --help|-h) usage; exit 0 ;;
        --list) list_only=1 ;;
        *)
            [[ $arg =~ ^[a-zA-Z_][a-zA-Z0-9_-]*= ]] || {
                printf 'Expected MAKE_VARIABLE=value, got: %s\n' "$arg" >&2; exit 2;
            }
            make_vars+=("$arg") ;;
    esac
done

declare -A app_dirs single_sources seen
available=()
register_app() {
    local name=$1 directory=$2 source=${3:-}
    [[ $name =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$ ]] || {
        printf 'Unsupported app name: %s\n' "$name" >&2; exit 2;
    }
    [[ ! ${app_dirs[$name]+present} ]] || {
        printf 'Duplicate app name: %s\n' "$name" >&2; exit 2;
    }
    available+=("$name")
    app_dirs[$name]=$directory
    single_sources[$name]=$source
}

# Only immediate firmware sources count: host tests and utility subdirectories
# are not applications. The legacy onnx directory contains two separate mains.
for directory in "$SW_DIR"/*; do
    [[ -d $directory ]] || continue
    name=${directory##*/}
    if [[ $name == onnx ]]; then
        for source in "$directory"/*.c; do
            stem=${source##*/}
            register_app "onnx_${stem%.c}" "$directory" "$source"
        done
    else
        sources=("$directory"/*.c "$directory"/*.S "$directory"/*.ll)
        if ((${#sources[@]})); then register_app "$name" "$directory"; fi
    fi
done
((${#available[@]})) || { echo 'No firmware applications found.' >&2; exit 2; }

selected=()
read -r -a requested <<< "${APPS:-}"
((${#requested[@]})) || requested=("${available[@]}")
for name in "${requested[@]}"; do
    [[ ${app_dirs[$name]+present} ]] || {
        printf 'Unknown app: %s (use --list)\n' "$name" >&2; exit 2;
    }
    if [[ ! ${seen[$name]+present} ]]; then
        selected+=("$name"); seen[$name]=1
    fi
done
if ((list_only)); then
    printf '%s\n' "${selected[@]}"
    exit 0
fi

cd -- "$SYSTEM_DIR"
APP_PATH=${APP_PATH:-"$SYSTEM_DIR/app-images"}
# Keep export cleanup away from build products and application source trees.
APP_PATH=$(realpath -m -- "$APP_PATH")
case "$APP_PATH/" in
    "$BIN_DIR/"*|"$SW_DIR/"*) echo 'APP_PATH must be outside sw/bin and ../sw.' >&2; exit 2 ;;
esac
mkdir -p -- "$APP_PATH/logs"
printf 'app\tstatus\timages\tlog\n' > "$APP_PATH/summary.tsv"
printf 'Building %d apps; collecting images in %s\n' "${#selected[@]}" "$APP_PATH"

build_app() {
    local name=$1 directory=${app_dirs[$1]} source
    local -a sources command images
    if [[ -n ${single_sources[$name]} ]]; then
        sources=("${single_sources[$name]}")
    else
        sources=("$directory"/*.c "$directory"/*.S "$directory"/*.ll)
    fi
    case "$name" in
        radar_beamforming)
            # Default runtime3 backend; exclude any previously generated graph.ll.
            sources=("$directory/main.c" "$directory/beamform_runtime.c") ;;
        radar_candidate_attention)
            # Full chain from the separately supplied candidate-attention app.
            sources=("$directory/main.c" "$directory/candidate_features.c"
                     "$directory/candidate_runtime.c" "$SW_DIR/radar_beamforming/beamform_runtime.c") ;;
    esac
    command=("$MAKE_BIN" -C "$SYSTEM_DIR" -f Makefile "${make_vars[@]}"
             "PE=" "TEST=$name" "TEST_SRC_DIR=$directory" "TEST_FILES=${sources[*]}"
             "TEST_BIN_DIR=$BIN_DIR" "test-program=$BIN_DIR/$name")
    printf 'Clean command: '; printf '%q ' "${command[@]}" test-clean; printf '\n'
    "${command[@]}" test-clean || return 1
    # test-clean only covers TEST_SRC_DIR. Also invalidate shared source objects
    # (e.g. beamform_runtime.o), since make does not track compiler flag changes.
    for source in "${sources[@]}"; do
        rm -f -- "${source%.*}.o" "${source%.*}.d" || return 1
    done
    printf 'Build command: '; printf '%q ' "${command[@]}" test-build; printf '\n'
    "${command[@]}" test-build || return 1
    [[ -s $BIN_DIR/$name-m.ihex && -s $BIN_DIR/$name-d.ihex ]] || {
        echo 'Build did not produce a nonempty instruction/data IHEX pair.'; return 1;
    }
    images=("$BIN_DIR/$name"-*.ihex)
    cp -- "${images[@]}" "$APP_PATH/" || return 1
    image_count=${#images[@]}
}

passed=0
failed=0
for name in "${selected[@]}"; do
    log="$APP_PATH/logs/$name.log"
    old_images=("$APP_PATH/$name"-*.ihex)
    ((${#old_images[@]} == 0)) || rm -f -- "${old_images[@]}"
    image_count=0
    printf '  %-30s ' "$name"
    if build_app "$name" > "$log" 2>&1; then
        printf 'PASS (%d images)\n' "$image_count"
        printf '%s\tPASS\t%d\t%s\n' "$name" "$image_count" "$log" >> "$APP_PATH/summary.tsv"
        ((passed+=1))
    else
        # A partial copy is also a failed export.
        partial=("$APP_PATH/$name"-*.ihex)
        ((${#partial[@]} == 0)) || rm -f -- "${partial[@]}"
        printf 'FAIL (see %s)\n' "$log"
        printf '%s\tFAIL\t0\t%s\n' "$name" "$log" >> "$APP_PATH/summary.tsv"
        ((failed+=1))
    fi
done
printf '\nFinished: %d passed, %d failed. Summary: %s/summary.tsv\n' "$passed" "$failed" "$APP_PATH"
((failed == 0))
