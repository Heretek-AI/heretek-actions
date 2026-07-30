#!/usr/bin/env bash
# build-envelope.sh — Parse MegaLinter JSON report and write .agent/output.json
#
# Reads REPORT_PATH (default: megalinter-report.json) and maps each linter
# category to a checks[] entry and each individual finding to a
# findings[] entry. Falls back to a synthesized envelope when the report
# is missing or unreadable so downstream consumers never see an empty
# envelope.
#
# Sources agent-envelope.sh for write_envelope() and add_finding().

set -euo pipefail

source "${AGENT_ACTION_PATH}/../agent-envelope.sh"

REPORT_PATH="${REPORT_PATH:-megalinter-report.json}"
REPORT_PATH="${REPORT_PATH%.json}.json"  # normalize

echo "==> Parsing MegaLinter report: ${REPORT_PATH}"

if [ ! -f "${REPORT_PATH}" ]; then
  echo "::warning::No MegaLinter report found at ${REPORT_PATH}; writing empty envelope"
  AGENT_OUTPUTS='{"linter":"unknown","report_path":"'"${REPORT_PATH}"'","report_found":false}'
  AGENT_CHECKS='[]'
  AGENT_FINDINGS='[]'
  write_envelope "lint-ultimate" "failure" "no megalinter report found"
  echo "findings_count=0" >> "$GITHUB_OUTPUT"
  exit 0
fi

if ! command -v jq &>/dev/null; then
  echo "::error::jq is required to parse the MegaLinter report"
  exit 1
fi

# Pull linter categories (top-level keys with a "findings" array).
# MegaLinter's report shape: { "linter_key": { "findings": [...], "status": "success"/"warning"/"error" }, ... }
LINTER_KEYS=$(jq -r 'keys[] | select(. as $k | $k | startswith("$") | not)' "${REPORT_PATH}" 2>/dev/null || echo "")

if [ -z "${LINTER_KEYS}" ]; then
  echo "::warning::Report has no linter keys; treating as empty"
  AGENT_OUTPUTS='{"linter":"unknown","report_path":"'"${REPORT_PATH}"'","report_found":true,"findings_total":0}'
  write_envelope "lint-ultimate" "success" "no findings (empty report)"
  echo "findings_count=0" >> "$GITHUB_OUTPUT"
  exit 0
fi

# Aggregate stats
TOTAL_ERRORS=0
TOTAL_WARNINGS=0
LINTER_COUNT=0
FINDINGS_COUNT=0

# Build checks[] and findings[] via the helpers.
while IFS= read -r linter; do
  [ -z "${linter}" ] && continue
  LINTER_COUNT=$((LINTER_COUNT + 1))

  # Status: error > warning > success
  LINT_STATUS=$(jq -r --arg k "${linter}" '
    if (.[$k] | type) == "object" and (.[$k].status // null) != null then .[$k].status
    elif (.[$k] | type) == "object" and ((.[$k].findings // []) | length) > 0 then "warning"
    else "success" end
  ' "${REPORT_PATH}")

  FINDING_COUNT_FOR_LINTER=$(jq -r --arg k "${linter}" '
    if (.[$k] | type) == "object" then ((.[$k].findings // []) | length)
    else 0 end
  ' "${REPORT_PATH}")

  case "${LINT_STATUS}" in
    error)   TOTAL_ERRORS=$((TOTAL_ERRORS + 1)) ;;
    warning) TOTAL_WARNINGS=$((TOTAL_WARNINGS + 1)) ;;
  esac

  CHECK_STATUS="pass"
  case "${LINT_STATUS}" in
    error)   CHECK_STATUS="fail" ;;
    warning) CHECK_STATUS="warn" ;;
  esac

  add_check "${linter}" "${CHECK_STATUS}" "${FINDING_COUNT_FOR_LINTER} finding(s)"

  # Each finding -> add_finding()
  while IFS=$'\t' read -r severity file line column message rule; do
    [ -z "${severity:-}" ] && continue
    FINDINGS_COUNT=$((FINDINGS_COUNT + 1))
    add_finding "${severity}" "${message}" "${rule}" "${file}" "${line}" "${column}" ""
  done < <(jq -r --arg k "${linter}" '
    (.[$k].findings // [])[] |
    [
      (.severity // "warning"),
      (.filename // .file // ""),
      ((.line // 0) | tostring),
      ((.column // 0) | tostring),
      (.message // ""),
      (.linter_rule_key // .rule // $k)
    ] | @tsv
  ' "${REPORT_PATH}")

done <<< "${LINTER_KEYS}"

# Overall status
if [ "${TOTAL_ERRORS}" -gt 0 ]; then
  STATUS="failure"
elif [ "${TOTAL_WARNINGS}" -gt 0 ]; then
  STATUS="partial"
else
  STATUS="success"
fi

SUMMARY="lint-ultimate: ${FINDINGS_COUNT} finding(s) across ${LINTER_COUNT} linter(s)"
[ "${TOTAL_ERRORS}" -gt 0 ]   && SUMMARY+=", ${TOTAL_ERRORS} error(s)"
[ "${TOTAL_WARNINGS}" -gt 0 ] && SUMMARY+=", ${TOTAL_WARNINGS} warning(s)"

AGENT_OUTPUTS=$(jq -n \
  --arg report_path "${REPORT_PATH}" \
  --argjson linter_count "${LINTER_COUNT}" \
  --argjson findings_total "${FINDINGS_COUNT}" \
  --argjson errors "${TOTAL_ERRORS}" \
  --argjson warnings "${TOTAL_WARNINGS}" \
  '{
    report_path: $report_path,
    linter_count: $linter_count,
    findings_total: $findings_total,
    errors: $errors,
    warnings: $warnings
  }')
export AGENT_OUTPUTS

write_envelope "lint-ultimate" "${STATUS}" "${SUMMARY}"

echo "findings_count=${FINDINGS_COUNT}" >> "$GITHUB_OUTPUT"