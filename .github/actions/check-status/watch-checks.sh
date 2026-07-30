#!/usr/bin/env bash
set -euo pipefail

# Source the envelope helper
source "${AGENT_ACTION_PATH}/../agent-envelope.sh"

echo "👀 Watching check runs for ${HEAD_SHA}..."

WAIT_MAX="${WAIT_MAX:-600}"
POLL_INTERVAL="${POLL_INTERVAL:-15}"

owner="${GITHUB_REPOSITORY_OWNER:-}"
repo="${GITHUB_REPOSITORY#*/}"

start_time=$(date +%s)
elapsed=0
complete=false

while [ "$elapsed" -lt "$WAIT_MAX" ]; do
  # Fetch check runs
  CHECKS_DATA=$(gh api "repos/${owner}/${repo}/commits/${HEAD_SHA}/check-runs" \
    --jq '{
      total_count,
      check_runs: [.check_runs[] | {
        name,
        status,
        conclusion,
        html_url,
        started_at,
        completed_at,
        app: .app.name // "unknown"
      }]
    }' 2>/dev/null || echo '{"total_count": 0, "check_runs": []}')

  TOTAL_COUNT=$(echo "$CHECKS_DATA" | jq -r '.total_count // 0')
  INCOMPLETE=$(echo "$CHECKS_DATA" | jq '[.check_runs[] | select(.status != "completed")] | length')
  FAILURES=$(echo "$CHECKS_DATA" | jq '[.check_runs[] | select(.conclusion == "failure" or .conclusion == "cancelled" or .conclusion == "timed_out" or .conclusion == "action_required")] | length')
  SUCCESSES=$(echo "$CHECKS_DATA" | jq '[.check_runs[] | select(.conclusion == "success" or .conclusion == "neutral")] | length')
  PENDING=$(echo "$CHECKS_DATA" | jq '[.check_runs[] | select(.status == "queued" or .status == "in_progress")] | length')

  echo "  checks: ${TOTAL_COUNT} total, ${SUCCESSES} passed, ${FAILURES} failed, ${INCOMPLETE} incomplete"

  if [ "$INCOMPLETE" -eq 0 ] && [ "$TOTAL_COUNT" -gt 0 ]; then
    complete=true
    break
  fi

  if [ "$TOTAL_COUNT" -eq 0 ] && [ "$elapsed" -gt 60 ]; then
    # No checks after 60 seconds — likely no CI configured
    break
  fi

  sleep "$POLL_INTERVAL"
  elapsed=$(( $(date +%s) - start_time ))
done

# Build check list
CHECKS=$(echo "$CHECKS_DATA" | jq '[.check_runs[] | {name, status: (.conclusion // .status), details_url: .html_url}]')

# Determine overall status
if [ "$complete" = true ]; then
  if [ "$FAILURES" -gt 0 ]; then
    OVERALL_STATUS="failure"
    SUMMARY="${FAILURES} check(s) failed, ${SUCCESSES} passed"
  else
    OVERALL_STATUS="success"
    SUMMARY="${SUCCESSES} check(s) all passed"
  fi
elif [ "$elapsed" -ge "$WAIT_MAX" ]; then
  OVERALL_STATUS="timeout"
  SUMMARY="${PENDING} check(s) still running after ${WAIT_MAX}s timeout"
else
  OVERALL_STATUS="running"
  SUMMARY="${TOTAL_COUNT} check(s) found, ${INCOMPLETE} still running"
fi

# Build outputs
AGENT_OUTPUTS=$(cat <<OUTPUTS
{
  "head_sha": "${HEAD_SHA}",
  "total_checks": ${TOTAL_COUNT},
  "passed": ${SUCCESSES},
  "failed": ${FAILURES},
  "pending": ${PENDING},
  "elapsed_seconds": ${elapsed},
  "all_complete": ${complete},
  "wait_timed_out": $( [ "$elapsed" -ge "$WAIT_MAX" ] && echo true || echo false )
}
OUTPUTS
export AGENT_OUTPUTS

# Build suggestions
SUGGESTIONS='[]'
if [ "$OVERALL_STATUS" = "success" ]; then
  if [ -n "${PR_NUMBER:-}" ]; then
    add_suggestion "pr:merge" "All checks passed" \
      "{\"pr_number\": ${PR_NUMBER}, \"merge_method\": \"squash\"}" "high"
  fi
elif [ "$OVERALL_STATUS" = "failure" ]; then
  add_suggestion "comment:post" "${FAILURES} check(s) failed — review details before proceeding" "{}" "high"
fi

write_envelope "check-status" "$OVERALL_STATUS" "$SUMMARY"

echo "status=${OVERALL_STATUS}" >> "$GITHUB_OUTPUT"
echo "summary=${SUMMARY}" >> "$GITHUB_OUTPUT"
