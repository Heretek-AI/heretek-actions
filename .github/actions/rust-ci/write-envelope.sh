#!/usr/bin/env bash
set -euo pipefail

source "${AGENT_ACTION_PATH}/../agent-envelope.sh"

echo "📝 Generating Rust CI envelope..."

# Parse exit codes
FMT_OK=1; [ "${FMT_EXIT:-0}" = "0" ] 2>/dev/null && FMT_OK=0 || true
CLIPPY_OK=1; [ "${CLIPPY_EXIT:-0}" = "0" ] 2>/dev/null && CLIPPY_OK=0 || true
TEST_OK=1; [ "${TEST_EXIT:-0}" = "0" ] 2>/dev/null && TEST_OK=0 || true
AUDIT_OK=1; [ "${AUDIT_EXIT:-0}" = "0" ] 2>/dev/null && AUDIT_OK=0 || true
COV_OK=1; [ "${COV_EXIT:-0}" = "0" ] 2>/dev/null && COV_OK=0 || true

# Parse test output for pass/fail counts
TEST_PASS=0
TEST_FAIL=0
if [ -f .test-output.txt ]; then
  TEST_PASS=$(grep -oP '\d+(?= passed)' .test-output.txt 2>/dev/null | paste -sd+ | bc 2>/dev/null || echo 0)
  TEST_FAIL=$(grep -oP '\d+(?= failed)' .test-output.txt 2>/dev/null | paste -sd+ | bc 2>/dev/null || echo 0)
fi

# Parse audit findings
AUDIT_VULNS=0
if [ -f .audit-output.txt ]; then
  AUDIT_VULNS=$(grep -c "CVE-" .audit-output.txt 2>/dev/null || echo 0)
fi

# Determine status
ERRORS=0
[ "$FMT_OK" -eq 1 ] && ERRORS=$((ERRORS+1))
[ "$CLIPPY_OK" -eq 1 ] && ERRORS=$((ERRORS+1))
[ "$TEST_OK" -eq 1 ] && ERRORS=$((ERRORS+1))

if [ "$ERRORS" -gt 0 ]; then
  STATUS="failure"
elif [ "$AUDIT_VULNS" -gt 0 ]; then
  STATUS="partial"
else
  STATUS="success"
fi

SUMMARY="rust-ci: "
SUMMARY+="fmt=$([ "$FMT_OK" -eq 0 ] && echo '✓' || echo '✗') "
SUMMARY+="clippy=$([ "$CLIPPY_OK" -eq 0 ] && echo '✓' || echo '✗') "
SUMMARY+="test=${TEST_PASS}✓/${TEST_FAIL}✗ "
if [ -n "${AUDIT_EXIT:-}" ]; then
  SUMMARY+="audit=${AUDIT_VULNS}vulns "
fi

# Build outputs
AGENT_OUTPUTS=$(cat <<OUTPUTS
{
  "toolchain": "${{ inputs.toolchain }}",
  "checks": {
    "fmt": {"passed": $([ "$FMT_OK" -eq 0 ] && echo true || echo false)},
    "clippy": {"passed": $([ "$CLIPPY_OK" -eq 0 ] && echo true || echo false)},
    "test": {"passed": $([ "$TEST_OK" -eq 0 ] && echo true || echo false), "passed_count": ${TEST_PASS}, "failed_count": ${TEST_FAIL}},
    "audit": {"passed": $([ "$AUDIT_OK" -eq 0 ] && echo true || echo false), "vulnerabilities": ${AUDIT_VULNS}},
    "coverage": {"passed": $([ "$COV_OK" -eq 0 ] && echo true || echo false), "enabled": $([ "${{ inputs.enable-coverage }}" = "true" ] && echo true || echo false)}
  }
}
OUTPUTS
)
export AGENT_OUTPUTS

write_envelope "ci-rust" "$STATUS" "$SUMMARY"

echo "status=${STATUS}" >> "$GITHUB_OUTPUT"
echo "summary=${SUMMARY}" >> "$GITHUB_OUTPUT"
