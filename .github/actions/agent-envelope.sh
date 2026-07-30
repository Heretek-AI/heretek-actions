#!/usr/bin/env bash
# agent-envelope.sh — Write a standardized .agent/output.json from any action
#
# Usage: source ./agent-envelope.sh && write_envelope "action-name" "status" "summary"
#
# All actions should source this file and call write_envelope at the end.
# Override defaults by setting env vars before calling:
#   AGENT_OUTPUTS=...   — JSON object for the "outputs" field
#   AGENT_SUGGESTIONS=... — JSON array for the "suggestions" field
#   AGENT_CHECKS=...    — JSON array for the "checks" field
#   AGENT_FINDINGS=...  — JSON array for the "findings" field
#   AGENT_RELEASE=...   — JSON object for the "release" field

: "${AGENT_OUTPUT_DIR:=${GITHUB_WORKSPACE:-.}/.agent}"
: "${AGENT_ENVELOPE_FILE:=${AGENT_OUTPUT_DIR}/output.json}"

write_envelope() {
  local action="$1"
  local status="$2"
  local summary="$3"

  mkdir -p "$AGENT_OUTPUT_DIR"

  local created_at
  created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Ensure defaults for JSON variables.
  # NOTE: Use separate if blocks, NOT :-{}/:-[]/:-null defaults in parameter expansion —
  # bash interprets the first } after :- as closing the ${} expression, producing
  # an extra literal } that corrupts the JSON (e.g. "outputs": {...}} instead of "outputs": {...}).
  if [ -z "${AGENT_OUTPUTS:-}" ]; then AGENT_OUTPUTS='{}'; fi
  if [ -z "${AGENT_SUGGESTIONS:-}" ]; then AGENT_SUGGESTIONS='[]'; fi
  if [ -z "${AGENT_CHECKS:-}" ]; then AGENT_CHECKS='[]'; fi
  if [ -z "${AGENT_FINDINGS:-}" ]; then AGENT_FINDINGS='[]'; fi
  if [ -z "${AGENT_RELEASE:-}" ]; then AGENT_RELEASE='null'; fi

  # Build envelope — prefer jq, fall back to cat
  # Default GITHUB_REPOSITORY first to keep `set -u` callers (tests, local
  # sandbox) from triggering unbound-variable errors. Strip the owner
  # prefix to match the existing repository.repo semantics.
  # Coerce GITHUB_RUN_ID to actual `null` (not empty string) before
  # passing to jq; jq 1.8.2 silently produces no output when
  # `tonumber?` on an empty arg is used in a top-level object context.
  : "${GITHUB_REPOSITORY:=}"
  _repo_name="${GITHUB_REPOSITORY##*/}"
  if [ -z "${GITHUB_RUN_ID:-}" ]; then
    _run_id_arg='--argjson run_id null'
  else
    _run_id_arg="--argjson run_id ${GITHUB_RUN_ID}"
  fi
  if command -v jq &>/dev/null && jq -n \
    --arg action "$action" \
    --arg version "1.0" \
    --arg status "$status" \
    --arg summary "$summary" \
    --arg created_at "$created_at" \
    --arg duration_ms "${AGENT_DURATION_MS:-0}" \
    --argjson outputs "${AGENT_OUTPUTS}" \
    --argjson suggestions "${AGENT_SUGGESTIONS}" \
    --argjson checks "${AGENT_CHECKS}" \
    --argjson findings "${AGENT_FINDINGS}" \
    --argjson release "${AGENT_RELEASE}" \
    --arg repo_owner "${GITHUB_REPOSITORY_OWNER:-}" \
    --arg repo_name "${_repo_name}" \
    --arg sha "${GITHUB_SHA:-}" \
    --arg ref "${GITHUB_REF:-}" \
    --arg workflow "${GITHUB_WORKFLOW:-}" \
    ${_run_id_arg} \
    '{
      agent_action: $action,
      version: $version,
      status: $status,
      summary: $summary,
      created_at: $created_at,
      duration_ms: ($duration_ms | tonumber),
      outputs: $outputs,
      suggestions: $suggestions,
      checks: $checks,
      findings: $findings,
      release: $release,
      repository: {
        owner: $repo_owner,
        repo: $repo_name,
        sha: $sha,
        ref: $ref,
        workflow: $workflow,
        run_id: $run_id
      }
    }' > "$AGENT_ENVELOPE_FILE" 2>/dev/null; then
    :  # jq succeeded
  else
    # Fallback — simple JSON without jq
    cat > "$AGENT_ENVELOPE_FILE" <<ENVELOPE
{
  "agent_action": "${action}",
  "version": "1.0",
  "status": "${status}",
  "summary": "${summary}",
  "created_at": "${created_at}",
  "duration_ms": ${AGENT_DURATION_MS:-0},
  "outputs": ${AGENT_OUTPUTS},
  "suggestions": ${AGENT_SUGGESTIONS},
  "checks": ${AGENT_CHECKS},
  "findings": ${AGENT_FINDINGS},
  "release": ${AGENT_RELEASE},
  "repository": {
    "owner": "${GITHUB_REPOSITORY_OWNER:-}",
    "repo": "${GITHUB_REPOSITORY#*/}",
    "sha": "${GITHUB_SHA:-}",
    "ref": "${GITHUB_REF:-}",
    "workflow": "${GITHUB_WORKFLOW:-}",
    "run_id": ${GITHUB_RUN_ID:-null}
  }
}
ENVELOPE
  fi

  # Also emit as GitHub Action output
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
      echo "agent_action=${action}"
      echo "status=${status}"
      echo "summary=${summary}"
    } >> "$GITHUB_OUTPUT"
  fi

  echo "✓ Wrote agent envelope: ${AGENT_ENVELOPE_FILE}"
  echo "  action=${action} status=${status} summary=${summary}"
}

# Helper to add a suggestion
add_suggestion() {
  local type="$1"
  local reason="$2"
  local data="${3:-{}}"
  local priority="${4:-medium}"

  if [ -z "${AGENT_SUGGESTIONS:-}" ]; then
    AGENT_SUGGESTIONS='[]'
  fi

  local suggestion
  suggestion=$(cat <<SUGGESTION
{"type":"${type}","reason":"${reason}","data":${data},"priority":"${priority}"}
SUGGESTION
  )

  if command -v jq &>/dev/null; then
    AGENT_SUGGESTIONS=$(echo "$AGENT_SUGGESTIONS" | jq --argjson s "$suggestion" '. + [$s]')
  else
    AGENT_SUGGESTIONS=$(echo "$AGENT_SUGGESTIONS" | sed 's/\]$/,/' | (cat - && echo "${suggestion}]"))
  fi
  export AGENT_SUGGESTIONS
}

# Helper to add a check result
add_check() {
  local name="$1"
  local status="$2"  # pass/fail/warn/skip/error
  local summary="${3:-}"

  local check
  check=$(cat <<CHECK
{"name":"${name}","status":"${status}","summary":"${summary}"}
CHECK
  )

  if [ -z "${AGENT_CHECKS:-}" ]; then
    AGENT_CHECKS='[]'
  fi

  if command -v jq &>/dev/null; then
    AGENT_CHECKS=$(echo "$AGENT_CHECKS" | jq --argjson c "$check" '. + [$c]')
  else
    AGENT_CHECKS=$(echo "$AGENT_CHECKS" | sed 's/\]$/,/' | (cat - && echo "${check}]"))
  fi
  export AGENT_CHECKS
}

# Helper to add a finding (lint error, vuln, etc.)
#
# Usage: add_finding <severity> <message> [rule] [file] [line] [column] [suggested_fix]
#
# Severity must be one of: error, warning, info, note (matches
# .agent/schema.json findings[].severity enum).
add_finding() {
  local severity="$1"
  local message="$2"
  local rule="${3:-}"
  local file="${4:-}"
  local line="${5:-}"
  local column="${6:-}"
  local suggested_fix="${7:-}"

  if [ -z "${AGENT_FINDINGS:-}" ]; then
    AGENT_FINDINGS='[]'
  fi

  # Build JSON via jq for safety; jq nullifies unset optional fields.
  local finding
  if command -v jq &>/dev/null; then
    finding=$(jq -n \
      --arg severity "$severity" \
      --arg rule "$rule" \
      --arg file "$file" \
      --arg message "$message" \
      --arg suggested_fix "$suggested_fix" \
      --arg line "$line" \
      --arg column "$column" \
      '{
        severity: $severity,
        message: $message,
        rule: (if $rule == "" then null else $rule end),
        file: (if $file == "" then null else $file end),
        line: (if $line == "" then null else ($line | tonumber) end),
        column: (if $column == "" then null else ($column | tonumber) end),
        suggested_fix: (if $suggested_fix == "" then null else $suggested_fix end)
      }')
  else
    # No-jq fallback: omit empty optional fields; coerce line/column to
    # numbers only when non-empty. Message and severity are always strings.
    local rule_json="null"
    [ -n "$rule" ] && rule_json="\"$rule\""
    local file_json="null"
    [ -n "$file" ] && file_json="\"$file\""
    local line_json="null"
    [ -n "$line" ] && line_json="$line"
    local column_json="null"
    [ -n "$column" ] && column_json="$column"
    local fix_json="null"
    [ -n "$suggested_fix" ] && fix_json="\"$suggested_fix\""
    finding=$(cat <<FINDING
{"severity":"${severity}","message":"${message}","rule":${rule_json},"file":${file_json},"line":${line_json},"column":${column_json},"suggested_fix":${fix_json}}
FINDING
    )
  fi

  if command -v jq &>/dev/null; then
    AGENT_FINDINGS=$(echo "$AGENT_FINDINGS" | jq --argjson f "$finding" '. + [$f]')
  else
    AGENT_FINDINGS=$(echo "$AGENT_FINDINGS" | sed 's/\]$/,/' | (cat - && echo "${finding}]"))
  fi
  export AGENT_FINDINGS
}
