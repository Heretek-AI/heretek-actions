#!/usr/bin/env bash
# tests/run-all.sh — Run all action/fixture pairs and report a summary
#
# Usage:
#   tests/run-all.sh                # run everything, parallel
#   tests/run-all.sh --serial       # run sequentially
#   tests/run-all.sh --dry-run      # print the matrix, don't execute
#   tests/run-all.sh --only rust-ci # run only matching actions
#   tests/run-all.sh --jobs 4       # parallel worker count (default: nproc)
#
# Exit codes:
#   0 — every pair passed (or matched golden / first-run snapshot)
#   1 — one or more pairs failed
#   2 — bad usage / environment

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES_DIR="${REPO_ROOT}/tests/fixtures"
RESULTS_DIR="${REPO_ROOT}/tests/work/results"

SERIAL=false
DRY_RUN=false
ONLY=""
JOBS="$(nproc 2>/dev/null || echo 4)"

while [ $# -gt 0 ]; do
  case "$1" in
    --serial)   SERIAL=true ;;
    --dry-run)  DRY_RUN=true ;;
    --only)     ONLY="${2:-}"; shift ;;
    --jobs)     JOBS="${2:-4}"; shift ;;
    -h|--help)
      sed -n '2,15p' "$0"
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

# Action matrix: maps fixture glob → action + extra args.
# Format: "<fixture-glob>|<action>|<action-args>"
#   fixture-glob  — shell glob under tests/fixtures
#   action        — composite action name (must exist under .github/actions/)
#   action-args   — extra args forwarded to run-action.sh
MATRIX=(
  "rust-*|rust-ci|"
  "js-*|js-ci|"
  "python-*|python-ci|"
  "docker-*|release|release-type=docker dockerfile=./Dockerfile"
  "megalinter-passing|lint-ultimate|"
  "megalinter-failing|lint-ultimate|"
)

# Expand matrix into concrete pairs
PAIRS=()
for entry in "${MATRIX[@]}"; do
  glob="${entry%%|*}"
  rest="${entry#*|}"
  action="${rest%%|*}"
  args="${rest#*|}"

  if [ -n "${ONLY}" ] && [ "${action}" != "${ONLY}" ]; then
    continue
  fi

  # shellcheck disable=SC2206
  matches=(${FIXTURES_DIR}/${glob}/)
  if [ ${#matches[@]} -eq 0 ] || [ ! -d "${matches[0]}" ]; then
    continue
  fi

  for fixture_path in "${matches[@]}"; do
    fixture="$(basename "${fixture_path}")"
    PAIRS+=("${fixture}|${action}|${args}")
  done
done

if [ ${#PAIRS[@]} -eq 0 ]; then
  echo "no fixture/action pairs to run" >&2
  exit 2
fi

echo "==> ${#PAIRS[@]} pair(s) queued, jobs=${JOBS} mode=$( [ "${SERIAL}" = true ] && echo serial || echo parallel )"
echo

mkdir -p "${RESULTS_DIR}"

# Run one pair, capture exit code into a marker file.
run_pair() {
  local pair="$1"
  local fixture="${pair%%|*}"
  local rest="${pair#*|}"
  local action="${rest%%|*}"
  local args="${rest#*|}"

  local marker="${RESULTS_DIR}/${action}__${fixture}.exit"
  local log="${RESULTS_DIR}/${action}__${fixture}.log"

  echo "--- ${action} / ${fixture} ---"
  # shellcheck disable=SC2086
  if "${REPO_ROOT}/tests/run-action.sh" "${fixture}" "${action}" ${args} >"${log}" 2>&1; then
    echo "0" > "${marker}"
  else
    echo "$?" > "${marker}"
  fi
}

export -f run_pair
export REPO_ROOT FIXTURES_DIR RESULTS_DIR

# Dry-run: print matrix and exit
if [ "${DRY_RUN}" = true ]; then
  for pair in "${PAIRS[@]}"; do
    fixture="${pair%%|*}"
    rest="${pair#*|}"
    action="${rest%%|*}"
    echo "  ${action} / ${fixture}"
  done
  exit 0
fi

if [ "${SERIAL}" = true ]; then
  for pair in "${PAIRS[@]}"; do
    run_pair "${pair}"
  done
else
  printf '%s\n' "${PAIRS[@]}" | xargs -n1 -P "${JOBS}" -I{} bash -c 'run_pair "$@"' _ {}
fi

# Tally results
PASS=0
FAIL=0
FAILED_PAIRS=()

for pair in "${PAIRS[@]}"; do
  fixture="${pair%%|*}"
  rest="${pair#*|}"
  action="${rest%%|*}"
  marker="${RESULTS_DIR}/${action}__${fixture}.exit"

  if [ ! -f "${marker}" ]; then
    FAIL=$((FAIL + 1))
    FAILED_PAIRS+=("${action} / ${fixture} (no marker)")
    continue
  fi

  code="$(cat "${marker}")"
  if [ "${code}" = "0" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILED_PAIRS+=("${action} / ${fixture} (exit ${code})")
  fi
done

echo
echo "==> ${PASS} passed, ${FAIL} failed"

if [ ${FAIL} -gt 0 ]; then
  echo
  echo "Failures:"
  for f in "${FAILED_PAIRS[@]}"; do
    echo "  ✗ ${f}"
  done
  echo
  echo "Inspect logs under: ${RESULTS_DIR}/"
  exit 1
fi

exit 0
