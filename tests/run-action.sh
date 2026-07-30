#!/usr/bin/env bash
# tests/run-action.sh — Run a Heretek composite action against a fixture repo via `act`
#
# Usage:
#   tests/run-action.sh <fixture-name> <action-name> [act-args...]
#
# Example:
#   tests/run-action.sh rust-passing rust-ci
#   tests/run-action.sh js-failing js-ci --dryrun
#
# Exit codes:
#   0 — envelope produced and matches golden (or no golden exists yet)
#   1 — fixture missing
#   2 — envelope validation failed
#   3 — golden mismatch
#   4 — act itself failed

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES_DIR="${REPO_ROOT}/tests/fixtures"
GOLDEN_DIR="${REPO_ROOT}/tests/golden"
WORK_DIR="${REPO_ROOT}/tests/work"

FIXTURE="${1:-}"
ACTION="${2:-}"
shift 2 || true

if [ -z "${FIXTURE}" ] || [ -z "${ACTION}" ]; then
  echo "Usage: $0 <fixture-name> <action-name> [act-args...]" >&2
  exit 1
fi

FIXTURE_PATH="${FIXTURES_DIR}/${FIXTURE}"
if [ ! -d "${FIXTURE_PATH}" ]; then
  echo "fixture not found: ${FIXTURE_PATH}" >&2
  exit 1
fi

# Sandbox: copy fixture into work dir so act can checkout freely
SANDBOX="${WORK_DIR}/${FIXTURE}-$$"
mkdir -p "${SANDBOX}"
cp -R "${FIXTURE_PATH}/." "${SANDBOX}/"

# Wire up the local heretek-actions checkout as the action source
# Override GITHUB_ACTION_PATH or use local resolution via act's --action-ref
# Easiest path: mount the repo as the local actions source
mkdir -p "${SANDBOX}/.github/actions"
ln -sfn "${REPO_ROOT}/.github/actions/agent-envelope.sh" "${SANDBOX}/.github/actions/agent-envelope.sh"
ln -sfn "${REPO_ROOT}/.github/actions/${ACTION}" "${SANDBOX}/.github/actions/${ACTION}"

# Minimal workflow that calls the action and uploads the envelope
WORKFLOW_FILE="${SANDBOX}/.github/workflows/test-${ACTION}.yml"
mkdir -p "$(dirname "${WORKFLOW_FILE}")"
cat > "${WORKFLOW_FILE}" <<WORKFLOW
name: Test ${ACTION}
on: [push]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ./.github/actions/${ACTION}
        with: {}
      - name: Validate envelope against schema
        shell: bash
        run: |
          set -euo pipefail
          jq -e --schema '\${{ inputs.schema }}' '. | type == "object"' .agent/output.json >/dev/null
WORKFLOW

echo "==> Running ${ACTION} against fixture ${FIXTURE}"

# Run act. Capture output; tolerate non-zero exit (action may intentionally fail).
set +e
act -W "${WORKFLOW_FILE}" --container-architecture linux/amd64 "$@" 2>&1 | tee "${WORKDIR:-/tmp}/act-${FIXTURE}-${ACTION}.log"
ACT_EXIT=${PIPESTATUS[0]}
set -e

# Find the produced envelope
ENVELOPE="${SANDBOX}/.agent/output.json"
if [ ! -f "${ENVELOPE}" ]; then
  echo "no envelope produced (act exit ${ACT_EXIT})" >&2
  rm -rf "${SANDBOX}"
  exit 4
fi

# Validate against schema
if ! jq -e empty "${ENVELOPE}" >/dev/null 2>&1; then
  echo "envelope is not valid JSON: ${ENVELOPE}" >&2
  rm -rf "${SANDBOX}"
  exit 2
fi

# Validate schema enum fields (lightweight, no full JSON-schema validator needed)
SCHEMA="${REPO_ROOT}/.agent/schema.json"
AGENT_ACTION=$(jq -r '.agent_action' "${ENVELOPE}")
if ! jq -e --argjson env "${ENVELOPE}" '.properties.agent_action.enum | index($env.agent_action) != null' "${SCHEMA}" >/dev/null; then
  echo "envelope agent_action '${AGENT_ACTION}' not in schema enum" >&2
  rm -rf "${SANDBOX}"
  exit 2
fi

GOLDEN="${GOLDEN_DIR}/${ACTION}/${FIXTURE}.json"
if [ -f "${GOLDEN}" ]; then
  # Diff against golden — strip volatile fields (timestamps, run_id, sha)
  NORMALIZED=$(jq 'del(.created_at, .duration_ms, .repository.run_id, .repository.sha)' "${ENVELOPE}")
  GOLDEN_NORMALIZED=$(jq 'del(.created_at, .duration_ms, .repository.run_id, .repository.sha)' "${GOLDEN}")
  if ! diff <(echo "${GOLDEN_NORMALIZED}") <(echo "${NORMALIZED}") >/dev/null; then
    echo "envelope differs from golden: ${GOLDEN}" >&2
    diff <(echo "${GOLDEN_NORMALIZED}") <(echo "${NORMALIZED}") >&2 || true
    rm -rf "${SANDBOX}"
    exit 3
  fi
  echo "✓ ${ACTION} on ${FIXTURE} matches golden"
else
  echo "no golden for ${ACTION}/${FIXTURE} — writing first-run snapshot"
  mkdir -p "${GOLDEN_DIR}/${ACTION}"
  jq 'del(.created_at, .duration_ms, .repository.run_id, .repository.sha)' "${ENVELOPE}" > "${GOLDEN}"
fi

rm -rf "${SANDBOX}"
exit 0
