#!/usr/bin/env bash
set -euo pipefail

# Source the envelope helper
source "${{ github.action_path }}/../agent-envelope.sh"

echo "🏷️ Triaging Issue #${ISSUE_NUMBER}: ${ISSUE_TITLE}"

AUTO_LABEL="${AUTO_LABEL:-true}"
POST_COMMENT="${POST_COMMENT:-true}"
DUPLICATE_THRESHOLD="${DUPLICATE_THRESHOLD:-0.7}"

owner="${GITHUB_REPOSITORY_OWNER:-}"
repo="${GITHUB_REPOSITORY#*/}"

# Classify issue type from title and body
classify_issue() {
  local title="$1"
  local body="$2"
  local combined
  combined=$(echo "${title} ${body}" | tr '[:upper:]' '[:lower:]')

  local labels_to_add=()

  # Bug detection
  if echo "$combined" | grep -qiE '\b(bug|crash|error|fail|wrong|incorrect|broken|issue|fix|regression|panic|exception)\b'; then
    labels_to_add+=("bug")
  fi

  # Feature request
  if echo "$combined" | grep -qiE '\b(feature|request|suggest|idea|would be nice|enhancement|want|wishlist|new:\|add:)\b'; then
    labels_to_add+=("enhancement")
  fi

  # Question
  if echo "$combined" | grep -qiE '\b(how|question|help|does this|can you|example|tutorial)\b.*\?'; then
    labels_to_add+=("question")
  fi

  # Documentation
  if echo "$combined" | grep -qiE '\b(doc|documentation|readme|typo|spelling|comment)\b'; then
    labels_to_add+=("documentation")
  fi

  # Security
  if echo "$combined" | grep -qiE '\b(security|cve|vulnerability|xss|injection|exploit|auth|permission)\b'; then
    labels_to_add+=("security")
  fi

  # Performance
  if echo "$combined" | grep -qiE '\b(performance|slow|latency|memory|leak|optimize|bottleneck)\b'; then
    labels_to_add+=("performance")
  fi

  # Needs more info
  if [ -z "${body:-}" ] || [ "${#body}" -lt 30 ]; then
    labels_to_add+=("needs-more-info")
  fi

  echo "${labels_to_add[@]}"
}

# Check for potential duplicates
check_duplicates() {
  local title="$1"
  local threshold="$2"

  # Get recent open issues
  local open_issues
  open_issues=$(gh api "repos/${owner}/${repo}/issues?state=open&per_page=50" \
    --jq '[.[] | {number, title, body: (.body // ""), labels: [.labels[].name]}]' 2>/dev/null || echo '[]')

  # Simple word-overlap similarity
  local title_words
  title_words=$(echo "$title" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '\n' | sort -u | grep -v '^$')

  local duplicates=()

  while IFS= read -r item; do
    local existing_title
    existing_title=$(echo "$item" | jq -r '.title // ""' | tr '[:upper:]' '[:lower:]')
    local existing_num
    existing_num=$(echo "$item" | jq -r '.number')

    if [ "$existing_num" = "${ISSUE_NUMBER}" ]; then
      continue
    fi

    # Count word overlap
    local overlap=0
    local total=0
    for word in $title_words; do
      total=$((total + 1))
      if echo "$existing_title" | grep -qi "\b${word}\b"; then
        overlap=$((overlap + 1))
      fi
    done

    if [ "$total" -gt 0 ]; then
      local similarity
      similarity=$(echo "scale=2; ${overlap} / ${total}" | bc 2>/dev/null || echo "0")
      if (( $(echo "$similarity >= $threshold" | bc -l 2>/dev/null || echo 0) )); then
        duplicates+=("$existing_num")
      fi
    fi
  done < <(echo "$open_issues" | jq -c '.[]' 2>/dev/null || echo '')

  echo "${duplicates[@]}"
}

# --- Main ---

# Classify
LABELS=($(classify_issue "${ISSUE_TITLE:-}" "${ISSUE_BODY:-}"))
DUPLICATES=($(check_duplicates "${ISSUE_TITLE:-}" "$DUPLICATE_THRESHOLD"))

# Apply labels
LABELS_JSON='[]'
if [ "$AUTO_LABEL" = "true" ] && [ ${#LABELS[@]} -gt 0 ]; then
  # Create labels if they don't exist (no-op if they already do)
  for label in "${LABELS[@]}"; do
    gh api "repos/${owner}/${repo}/labels" --field name="$label" --field color="ededed" > /dev/null 2>&1 || true
  done

  # Apply labels to issue
  gh api "repos/${owner}/${repo}/issues/${ISSUE_NUMBER}/labels" \
    --field labels="[$(printf '"%s",' "${LABELS[@]}" | sed 's/,$//')]" > /dev/null 2>&1 || true

  LABELS_JSON=$(printf '%s\n' "${LABELS[@]}" | jq -Rc '[inputs | select(length > 0)]')
fi

# Determine priority
PRIORITY="medium"
for label in "${LABELS[@]}"; do
  case "$label" in
    security) PRIORITY="high" ;;
    bug) PRIORITY="high" ;;
    performance) PRIORITY="medium" ;;
    enhancement) PRIORITY="low" ;;
  esac
done

# Build outputs
DUPLICATE_JSON='[]'
if [ ${#DUPLICATES[@]} -gt 0 ]; then
  DUPLICATE_JSON=$(printf '%s\n' "${DUPLICATES[@]}" | jq -Rc '[inputs | {issue: ., reason: "similar title"}]')
fi

AGENT_OUTPUTS=$(cat <<OUTPUTS
{
  "issue_number": ${ISSUE_NUMBER},
  "title": "${ISSUE_TITLE:-}",
  "author": "${ISSUE_AUTHOR:-}",
  "classification": {
    "labels": ${LABELS_JSON},
    "priority": "${PRIORITY}",
    "auto_assigned": ${AUTO_LABEL}
  },
  "potential_duplicates": ${DUPLICATE_JSON},
  "needs_more_info": $(echo "${LABELS_JSON}" | jq 'contains(["needs-more-info"])')
}
OUTPUTS
export AGENT_OUTPUTS

SUMMARY="Issue #${ISSUE_NUMBER}: classified as ${LABELS[*]:-(uncategorized)} | priority: ${PRIORITY}"
if [ ${#DUPLICATES[@]} -gt 0 ]; then
  SUMMARY="${SUMMARY} | potential duplicates: #${DUPLICATES[*]}"
fi

# Build suggestions
SUGGESTIONS='[]'
if [ ${#DUPLICATES[@]} -gt 0 ]; then
  add_suggestion "issue:close" "Potential duplicate of issues: #${DUPLICATES[*]}" \
    "{\"duplicates\": [${DUPLICATES[*]}]}" "medium"
fi
if echo "${LABELS_JSON}" | jq -e 'contains(["needs-more-info"])' > /dev/null 2>&1; then
  add_suggestion "comment:post" "Request more information from the author" "{}" "medium"
fi
if [ "$PRIORITY" = "high" ]; then
  add_suggestion "review:request" "High priority issue — needs maintainer attention" "{}" "high"
fi

write_envelope "issue-triage" "success" "$SUMMARY"

# Post triage comment
if [ "$POST_COMMENT" = "true" ]; then
  DUPLICATE_TEXT=""
  if [ ${#DUPLICATES[@]} -gt 0 ]; then
    DUPLICATE_TEXT="⚠️ **Potential duplicates detected:** "
    for dup in "${DUPLICATES[@]}"; do
      DUPLICATE_TEXT="${DUPLICATE_TEXT}[#${dup}](https://github.com/${owner}/${repo}/issues/${dup}) "
    done
    DUPLICATE_TEXT="${DUPLICATE_TEXT}

_If this is a duplicate, please close this issue._"
  fi

  COMMENT="## 🤖 Triage Summary

**Classification:** ${LABELS[*]:-(uncategorized)}
**Priority:** ${PRIORITY}

**Labels applied:**
$(echo "$LABELS_JSON" | jq -r '.[] | "- \`\(.)\`"')

${DUPLICATE_TEXT}

---
_Automated triage by [heretek-actions/issue-triage](https://github.com/Heretek-AI/heretek-actions)_"

  gh api "repos/${owner}/${repo}/issues/${ISSUE_NUMBER}/comments" \
    --field body="${COMMENT}" > /dev/null 2>&1 || true
fi

echo "status=success" >> "$GITHUB_OUTPUT"
echo "summary=${SUMMARY}" >> "$GITHUB_OUTPUT"
