#!/usr/bin/env bash
# tests/unit/test-lint-ultimate-parser.sh — Unit test for build-envelope.sh
#
# Runs the parser against a fabricated megalinter-report.json fixture
# and verifies the produced envelope shape. No Docker required.
#
# Exit codes:
#   0 — all assertions passed
#   1 — assertion failed
#   2 — environment error (missing jq, missing fixture)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURE="${REPO_ROOT}/tests/unit/fixtures/megalinter-report-sample.json"
ACTION="${REPO_ROOT}/.github/actions/lint-ultimate"

if ! command -v jq &>/dev/null; then
  echo "jq is required" >&2
  exit 2
fi

if [ ! -f "${FIXTURE}" ]; then
  echo "fixture missing: ${FIXTURE}" >&2
  exit 2
fi

# Sandbox: isolated AGENT_OUTPUT_DIR so we don't clobber anything
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

export AGENT_OUTPUT_DIR="${WORK}/.agent"
export GITHUB_OUTPUT="${WORK}/github_output"
export REPORT_PATH="${FIXTURE}"
export AGENT_ACTION_PATH="${ACTION}"

bash "${ACTION}/build-envelope.sh" > "${WORK}/run.log" 2>&1

ENVELOPE="${AGENT_OUTPUT_DIR}/output.json"
if [ ! -f "${ENVELOPE}" ]; then
  echo "no envelope produced; run log:" >&2
  cat "${WORK}/run.log" >&2
  exit 1
fi

assert_jq() {
  local jq_expr="$1"
  local expected="$2"
  local actual
  actual=$(jq -r "${jq_expr}" "${ENVELOPE}")
  if [ "${actual}" != "${expected}" ]; then
    echo "assertion failed: ${jq_expr}" >&2
    echo "  expected: ${expected}" >&2
    echo "  actual:   ${actual}" >&2
    exit 1
  fi
}

# Schema-level assertions
assert_jq '.agent_action'           "lint-ultimate"
assert_jq '.version'                "1.0"
assert_jq '.status'                 "partial"
assert_jq '.outputs.linter_count'   "2"
assert_jq '.outputs.findings_total' "3"
assert_jq '.outputs.errors'         "0"
assert_jq '.outputs.warnings'       "2"

# checks[] entries
assert_jq '.checks | length'        "2"
assert_jq '.checks[0].name'         "MARKDOWN_MARKDOWNLINT"
assert_jq '.checks[0].status'       "warn"
assert_jq '.checks[1].name'         "YAML_YAMLLINT"
assert_jq '.checks[1].status'       "warn"

# findings[] entries
assert_jq '.findings | length'             "3"
assert_jq '.findings[0].severity'          "warning"
assert_jq '.findings[0].rule'              "MD012"
assert_jq '.findings[0].file'              "README.md"
assert_jq '.findings[0].line'              "7"
assert_jq '.findings[1].rule'              "MD009"
assert_jq '.findings[2].rule'              "document-start"

# Volatile fields excluded from stability checks
assert_jq '.created_at | type'             "string"
# In a sandbox GITHUB_RUN_ID is unset, so repository.run_id is JSON null.
# In real CI it's a number.
assert_jq '.repository.run_id | (. == null or type == "number")' "true"

echo "✓ lint-ultimate parser unit test passed"
exit 0