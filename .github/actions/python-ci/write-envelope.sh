#!/usr/bin/env bash
set -euo pipefail

source "${{ github.action_path }}/../agent-envelope.sh"

echo "📝 Generating Python CI envelope..."

LINT_OK=1; [ "${LINT_EXIT:-0}" = "0" ] 2>/dev/null && LINT_OK=0 || true
TC_OK=1; [ "${TC_EXIT:-0}" = "0" ] 2>/dev/null && TC_OK=0 || true
TEST_OK=1; [ "${TEST_EXIT:-0}" = "0" ] 2>/dev/null && TEST_OK=0 || true

# Parse test output for pass/fail counts
TEST_PASS=0
TEST_FAIL=0
if [ -f .test-output.txt ]; then
  grep -E 'passed|failed' .test-output.txt | tail -1 | while IFS= read -r line; do
    if echo "$line" | grep -qP '\d+ passed'; then
      TEST_PASS=$(echo "$line" | grep -oP '\d+(?= passed)' || echo 0)
    fi
    if echo "$line" | grep -qP '\d+ failed'; then
      TEST_FAIL=$(echo "$line" | grep -oP '\d+(?= failed)' || echo 0)
    fi
    echo "TEST_PASS=${TEST_PASS}" >> "$GITHUB_ENV"
    echo "TEST_FAIL=${TEST_FAIL}" >> "$GITHUB_ENV"
  done
fi

ERRORS=0
[ "$LINT_OK" -eq 1 ] && ERRORS=$((ERRORS+1))
[ "$TC_OK" -eq 1 ] && ERRORS=$((ERRORS+1))
[ "$TEST_OK" -eq 1 ] && ERRORS=$((ERRORS+1))

if [ "$ERRORS" -gt 0 ]; then
  STATUS="failure"
else
  STATUS="success"
fi

SUMMARY="python-ci: lint=$([ "$LINT_OK" -eq 0 ] && echo '✓' || echo '✗') typecheck=$([ "$TC_OK" -eq 0 ] && echo '✓' || echo '✗') test=${TEST_PASS:-?}✓/${TEST_FAIL:-0}✗"

AGENT_OUTPUTS=$(cat <<OUTPUTS
{
  "package_manager": "${{ steps.detect.outputs.pm }}",
  "python_version": "${{ inputs.python-version }}",
  "checks": {
    "lint": {"passed": $([ "$LINT_OK" -eq 0 ] && echo 'true' || echo 'false')},
    "typecheck": {"passed": $([ "$TC_OK" -eq 0 ] && echo 'true' || echo 'false')},
    "test": {"passed": $([ "$TEST_OK" -eq 0 ] && echo 'true' || echo 'false'), "passed_count": ${TEST_PASS:-0}, "failed_count": ${TEST_FAIL:-0}}
  }
}
OUTPUTS
export AGENT_OUTPUTS

write_envelope "ci-python" "$STATUS" "$SUMMARY"

echo "status=${STATUS}" >> "$GITHUB_OUTPUT"
echo "summary=${SUMMARY}" >> "$GITHUB_OUTPUT"
