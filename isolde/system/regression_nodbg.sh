#!/usr/bin/env bash

set -u
set -o pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
log_dir=${REGRESSION_LOG_DIR:-"${script_dir}/regression-logs/${timestamp}-$$"}
make_bin=${MAKE_BIN:-make}

makefiles=(
  Makefile.cluster.nodbg
  Makefile.omp.nodbg
  Makefile.complex.nodbg
  Makefile.onnx-complex.nodbg
  Makefile.tile.nodbg
)

mkdir -p -- "${log_dir}"
cd -- "${script_dir}"

passed=0
failed=0

for makefile in "${makefiles[@]}"; do
  test_name=${makefile#Makefile.}
  test_name=${test_name%.nodbg}
  log_file="${log_dir}/${test_name}.log"

  printf '\n========== %s ==========' "${test_name}"
  printf '\nCommand: %s -f %s test-clean test-build veri-run\n\n' \
    "${make_bin}" "${makefile}"

  "${make_bin}" -f "${makefile}" test-clean test-build veri-run \
    2>&1 | tee "${log_file}"
  pipeline_status=("${PIPESTATUS[@]}")
  make_status=${pipeline_status[0]}
  tee_status=${pipeline_status[1]}

  marker_found=0
  if awk '
    {
      sub(/\r$/, "")
    }
    /^\[FPGA SIM\] @ t=[[:digit:]][[:digit:]]* - errors=00000000$/ {
      found = 1
    }
    END {
      exit(found ? 0 : 1)
    }
  ' "${log_file}"; then
    marker_found=1
  fi

  if (( make_status != 0 )); then
    printf 'ERROR: %s: make exited with status %d\n' \
      "${test_name}" "${make_status}" >&2
  fi

  if (( tee_status != 0 )); then
    printf 'ERROR: %s: could not save the complete output log\n' \
      "${test_name}" >&2
  fi

  if (( marker_found == 0 )); then
    printf '%s\n' \
      "ERROR: ${test_name}: success marker not found:" \
      '       [FPGA SIM] @ t=<digits> - errors=00000000' >&2
  fi

  if (( make_status == 0 && tee_status == 0 && marker_found == 1 )); then
    printf 'PASS: %s\n' "${test_name}"
    ((passed += 1))
  else
    printf 'FAIL: %s (log: %s)\n' "${test_name}" "${log_file}" >&2
    ((failed += 1))
  fi
done

printf '\nRegression summary: %d passed, %d failed\n' "${passed}" "${failed}"
printf 'Logs: %s\n' "${log_dir}"

if (( failed != 0 )); then
  exit 1
fi

printf 'All regression tests passed.\n'