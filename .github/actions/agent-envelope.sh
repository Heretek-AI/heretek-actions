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

set -euo pipefail

: "${AGENT_OUTPUT_DIR:=${GITHUB_WORKSPACE:-.}/.agent}"
: "${AGENT_ENVELOPE_FILE:=${AGENT_OUTPUT_DIR}/output.json}"

write_envelope() {
  local action="$1"
  local status="$2"
  local summary="$3"

  mkdir -p "$AGENT_OUTPUT_DIR"

  local created_at
  created_at="$(date -u +%Y-%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Build envelope via jq if available, otherwise cat+json
  if command -v jq &>/dev/null; then
    jq -n \
      --arg action "$action" \
      --arg version "1.0" \
      --arg status "$status" \
      --arg summary "$summary" \
      --arg created_at "$created_at" \
      --arg duration_ms "${AGENT_DURATION_MS:-0}" \
      --argjson outputs "${AGENT_OUTPUTS:-{}}" \
      --argjson suggestions "${AGENT_SUGGESTIONS:-[]}" \
      --argjson checks "${AGENT_CHECKS:-[]}" \
      --argjson findings "${AGENT_FINDINGS:-[]}" \
      --argjson release "${AGENT_RELEASE:-null}" \
      --arg repo_owner "${GITHUB_REPOSITORY_OWNER:-}" \
      --arg repo_name "${GITHUB_REPOSITORY#*/}" \
      --arg sha "${GITHUB_SHA:-}" \
      --arg ref "${GITHUB_REF:-}" \
      --arg workflow "${GITHUB_WORKFLOW:-}" \
      --arg run_id "${GITHUB_RUN_ID:-}" \
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
          run_id: ($run_id | tonumber?)
        }
      }' > "$AGENT_ENVELOPE_FILE"
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
  "outputs": ${AGENT_OUTPUTS:-{}},
  "suggestions": ${AGENT_SUGGESTIONS:-[]},
  "checks": ${AGENT_CHECKS:-[]},
  "findings": ${AGENT_FINDINGS:-[]},
  "release": ${AGENT_RELEASE:-null},
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
    AGENT_SUGGESTIONS=$(echo "$AGENT_SUGGESTIONS" | sed 's/\]$/,/' | (cat - && echo "${suggestion}]")
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
    AGENT_CHECKS=$(echo "$AGENT_CHECKS" | sed 's/\]$/,/' | (cat - && echo "${check}]")
  fi
  export AGENT_CHECKS
}
