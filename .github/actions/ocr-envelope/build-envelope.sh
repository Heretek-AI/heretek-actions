#!/usr/bin/env bash
set -euo pipefail

source "${AGENT_ACTION_PATH}/../agent-envelope.sh"

echo "📦 Building OCR agent envelope..."

OCR_RESULT_FILE="${OCR_RESULT_FILE:-.ocr/result.json}"
OCR_COMMAND="${OCR_COMMAND:-review}"

mkdir -p .agent

# Determine the agent action name
AGENT_ACTION="ocr-${OCR_COMMAND}"

# Default values if OCR output doesn't exist
STATUS="success"
SUMMARY="No OCR results found"
FINDINGS='[]'
ERROR_COUNT=0
WARNING_COUNT=0

if [ -f "$OCR_RESULT_FILE" ]; then
  echo "Reading OCR results from ${OCR_RESULT_FILE}"

  # Parse OCR JSON output — the format varies by OCR version
  # Common fields: issues, warnings, errors, summary, review_comments
  FINDINGS=$(cat "$OCR_RESULT_FILE" | jq '[.issues // (.review_comments // (.results // []))] | flatten' 2>/dev/null || echo '[]')

  # Count by severity
  ERROR_COUNT=$(echo "$FINDINGS" | jq '[.[] | select(.severity == "error" or .severity == "critical" or .severity == "high")] | length' 2>/dev/null || echo 0)
  WARNING_COUNT=$(echo "$FINDINGS" | jq '[.[] | select(.severity == "warning" or .severity == "medium")] | length' 2>/dev/null || echo 0)
  INFO_COUNT=$(echo "$FINDINGS" | jq '[.[] | select(.severity == "info" or .severity == "low" or .severity == "suggestion")] | length' 2>/dev/null || echo 0)

  # Determine status
  if [ "$ERROR_COUNT" -gt 0 ]; then
    STATUS="failure"
  elif [ "$WARNING_COUNT" -gt 0 ]; then
    STATUS="partial"
  else
    STATUS="success"
  fi

  # Build summary from OCR report
  REVIEW_SUMMARY=$(cat "$OCR_RESULT_FILE" | jq -r '.summary // (.review_summary // "\(.issues | length) issues found")' 2>/dev/null || echo "OCR ${OCR_COMMAND} completed")
  SUMMARY="${ERROR_COUNT} errors, ${WARNING_COUNT} warnings, ${INFO_COUNT:-0} info — ${REVIEW_SUMMARY}"

  # Build outputs containing the raw OCR data
  AGENT_OUTPUTS=$(cat "$OCR_RESULT_FILE" | jq '{ocr_command: $cmd, issue_count: (.issues | length)}' --arg cmd "$OCR_COMMAND" 2>/dev/null || echo '{}')
  export AGENT_OUTPUTS

  # Only include findings if there are any
  if [ "$(echo "$FINDINGS" | jq 'length' 2>/dev/null || echo 0)" -gt 0 ]; then
    export AGENT_FINDINGS="$FINDINGS"
  fi

  # Build suggestions
  SUGGESTIONS='[]'
  if [ "$ERROR_COUNT" -gt 0 ]; then
    add_suggestion "issue:create" "${ERROR_COUNT} error(s) found by OCR ${OCR_COMMAND}" \
      "{\"labels\": [\"ocr\", \"automated\"], \"title\": \"OCR findings: ${ERROR_COUNT} errors in ${OCR_COMMAND}\"}" "medium"
  fi
  if [ "$WARNING_COUNT" -gt 0 ]; then
    add_suggestion "comment:post" "${WARNING_COUNT} warning(s) — review before merge" "{}" "low"
  fi
  if [ "$OCR_COMMAND" = "review" ] && [ "$ERROR_COUNT" -eq 0 ] && [ "$WARNING_COUNT" -eq 0 ]; then
    add_suggestion "pr:merge" "OCR review passed, no issues found" "{\"merge_method\": \"squash\"}" "medium"
  fi
elif [ -f ".ocr/report.json" ]; then
  # Alternative OCR output path
  echo "Reading OCR results from .ocr/report.json"
  # Delegate to self with the alt path
  OCR_RESULT_FILE=".ocr/report.json" "${AGENT_ACTION_PATH}/build-envelope.sh"
  exit $?
fi

# Write the envelope
write_envelope "$AGENT_ACTION" "$STATUS" "$SUMMARY"

echo "status=${STATUS}" >> "$GITHUB_OUTPUT"
echo "summary=${SUMMARY}" >> "$GITHUB_OUTPUT"
echo "agent_action=${AGENT_ACTION}" >> "$GITHUB_OUTPUT"
