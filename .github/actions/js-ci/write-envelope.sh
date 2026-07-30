#!/usr/bin/env bash
set -euo pipefail

source "${AGENT_ACTION_PATH}/../agent-envelope.sh"

echo "📝 Generating JS/TS CI envelope..."

LINT_OK=1; [ "${LINT_EXIT:-0}" = "0" ] 2>/dev/null && LINT_OK=0 || true
TC_OK=1; [ "${TC_EXIT:-0}" = "0" ] 2>/dev/null && TC_OK=0 || true
TEST_OK=1; [ "${TEST_EXIT:-0}" = "0" ] 2>/dev/null && TEST_OK=0 || true

ERRORS=0
[ "$LINT_OK" -eq 1 ] && ERRORS=$((ERRORS+1))
[ "$TC_OK" -eq 1 ] && ERRORS=$((ERRORS+1))
[ "$TEST_OK" -eq 1 ] && ERRORS=$((ERRORS+1))

if [ "$ERRORS" -gt 0 ]; then
  STATUS="failure"
else
  STATUS="success"
fi

SUMMARY="js-ci: lint=$([ "$LINT_OK" -eq 0 ] && echo '✓' || echo '✗') typecheck=$([ "$TC_OK" -eq 0 ] && echo '✓' || echo '✗') test=$([ "$TEST_OK" -eq 0 ] && echo '✓' || echo '✗')"

AGENT_OUTPUTS=$(cat <<OUTPUTS
{
  "package_manager": "${{ steps.detect.outputs.pm }}",
  "checks": {
    "lint": {"passed": $([ "$LINT_OK" -eq 0 ] && echo 'true' || echo 'false')},
    "typecheck": {"passed": $([ "$TC_OK" -eq 0 ] && echo 'true' || echo 'false')},
    "test": {"passed": $([ "$TEST_OK" -eq 0 ] && echo 'true' || echo 'false')}
  }
}
OUTPUTS
)
export AGENT_OUTPUTS

write_envelope "ci-js" "$STATUS" "$SUMMARY"

echo "status=${STATUS}" >> "$GITHUB_OUTPUT"
echo "summary=${SUMMARY}" >> "$GITHUB_OUTPUT"
