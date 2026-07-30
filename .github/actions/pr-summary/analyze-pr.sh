#!/usr/bin/env bash
set -euo pipefail

# Source the envelope helper
source "${AGENT_ACTION_PATH}/../agent-envelope.sh"

echo "📝 Analyzing PR #${PR_NUMBER}: ${PR_TITLE}"

MAX_FILES="${MAX_FILES:-50}"
INCLUDE_DIFF_STATS="${INCLUDE_DIFF_STATS:-true}"
INCLUDE_REVIEWERS="${INCLUDE_REVIEWERS:-true}"
POST_COMMENT="${POST_COMMENT:-true}"

owner="${GITHUB_REPOSITORY_OWNER:-}"
repo="${GITHUB_REPOSITORY#*/}"

# Get PR diff stats
PR_DATA=$(gh api "repos/${owner}/${repo}/pulls/${PR_NUMBER}" --jq '{
  additions, deletions, changed_files,
  labels: [.labels[].name],
  milestone: .milestone.title // null,
  draft
}' 2>/dev/null || echo '{}')

ADDITIONS=$(echo "$PR_DATA" | jq -r '.additions // 0')
DELETIONS=$(echo "$PR_DATA" | jq -r '.deletions // 0')
CHANGED_FILES=$(echo "$PR_DATA" | jq -r '.changed_files // 0')
DRAFT=$(echo "$PR_DATA" | jq -r '.draft // false')
PR_LABELS=$(echo "$PR_DATA" | jq -r '.labels // []')

# Get file list with diff stats
FILES_DATA=$(gh api "repos/${owner}/${repo}/pulls/${PR_NUMBER}/files?per_page=${MAX_FILES}" \
  --jq '[.[] | {path, status, additions, deletions, changes, blob_url}]' 2>/dev/null || echo '[]')

# Categorize files by type
FILE_TYPES=$(echo "$FILES_DATA" | jq -r '
  group_by(.path | split(".") | last // "unknown") |
  map({type: .[0].path | split(".") | last // "unknown", count: length, changes: (map(.changes) | add)}) |
  sort_by(-.changes)
')

CATEGORIES=$(echo "$FILES_DATA" | jq -r '
  map(
    if .path | test("^src/|^lib/|^app/|^packages/|^crates/|^components/") then "source"
    elif .path | test("^test|^spec|^__tests__|_test\\.") then "test"
    elif .path | test("\\.(md|txt|rst|adoc)$") then "docs"
    elif .path | test("\\.(ya?ml|json|toml|ini|cfg)$") then "config"
    elif .path | test("\\.(css|scss|less|sass|styled\\.)" ) then "styles"
    elif .path | test("\\.(svg|png|jpg|gif|ico|webp)$") then "assets"
    elif .path | test("^ci/|^\\.github/|Dockerfile") then "ci"
    else "other"
    end
  ) | group_by(.) | map({category: .[0], count: length}) | sort_by(-.count)
')

# Extract linked issues from PR body and branch name
EXTRACTED_ISSUES=$(echo "${PR_BODY:-}" | grep -oE '#[0-9]+' | tr -d '#' | sort -u | jq -Rc '[inputs | {issue: ., source: "pr_body"}]' 2>/dev/null || echo '[]')
BRANCH_ISSUES=$(echo "${PR_HEAD:-}" | grep -oE '[0-9]+' | head -3 | jq -Rc '[{issue: ., source: "branch_name"}]' 2>/dev/null || echo '[]')

# Suggest reviewers from CODEOWNERS if available
SUGGESTED_REVIEWERS="[]"
if [ "$INCLUDE_REVIEWERS" = "true" ] && [ -f ".github/CODEOWNERS" ]; then
  CHANGED_PATHS=$(echo "$FILES_DATA" | jq -r '.[].path')
  # Simple heuristic: match CODEOWNERS patterns against changed files
  while IFS= read -r pattern_line; do
    pattern=$(echo "$pattern_line" | awk '{print $1}' || true)
    owners=$(echo "$pattern_line" | awk '{$1=""; print $0}' || true)
    if [ -n "$pattern" ] && [ -n "$owners" ]; then
      while IFS= read -r changed_file; do
        if [[ "$changed_file" == $pattern ]] 2>/dev/null; then
          for owner in $owners; do
            SUGGESTED_REVIEWERS=$(echo "$SUGGESTED_REVIEWERS" | jq --arg o "$owner" --arg f "$changed_file" \
              '. + [{"owner": $o, "file": $f}]' 2>/dev/null || echo "$SUGGESTED_REVIEWERS")
          done
        fi
      done <<< "$CHANGED_PATHS"
    fi
  done < <(grep -v '^\s*#' .github/CODEOWNERS | grep -v '^\s*$' || true)
fi

# Build outputs
AGENT_OUTPUTS=$(cat <<OUTPUTS
{
  "pr_number": ${PR_NUMBER},
  "title": "${PR_TITLE:-}",
  "author": "${PR_AUTHOR:-}",
  "base": "${PR_BASE:-}",
  "head": "${PR_HEAD:-}",
  "draft": ${DRAFT},
  "stats": {
    "additions": ${ADDITIONS},
    "deletions": ${DELETIONS},
    "changed_files": ${CHANGED_FILES},
    "labels": ${PR_LABELS}
  },
  "file_types": ${FILE_TYPES},
  "categories": ${CATEGORIES},
  "files": ${FILES_DATA},
  "linked_issues": {
    "from_pr_body": ${EXTRACTED_ISSUES},
    "from_branch": ${BRANCH_ISSUES}
  },
  "suggested_reviewers": ${SUGGESTED_REVIEWERS}
}
OUTPUTS
export AGENT_OUTPUTS

# Build summary
SUMMARY="${CHANGED_FILES} files changed, +${ADDITIONS}/-${DELETIONS} lines"

# Build suggestions
SUGGESTIONS='[]'
add_suggestion "none" "PR data collected for agent processing" "{}" "low"

# Suggest review if large PR
if [ "$CHANGED_FILES" -gt 10 ] || [ "$ADDITIONS" -gt 500 ]; then
  if [ -n "$SUGGESTED_REVIEWERS" ] && [ "$SUGGESTED_REVIEWERS" != "[]" ]; then
    REVIEWER_DATA=$(echo "$SUGGESTED_REVIEWERS" | jq '[.[].owner] | unique')
    add_suggestion "review:request" "Large PR ($CHANGED_FILES files, +$ADDITIONS) — request review from code owners" "${REVIEWER_DATA}" "high"
  else
    add_suggestion "review:request" "Large PR ($CHANGED_FILES files, +$ADDITIONS) — request review" "{}" "medium"
  fi
fi

write_envelope "pr-summary" "success" "$SUMMARY"

# Post PR comment if enabled
if [ "$POST_COMMENT" = "true" ]; then
  COMMENT=$(cat <<EOCOMMENT
## 📋 PR Summary

**${PR_TITLE}** by @${PR_AUTHOR}

### Stats
| Metric | Value |
|--------|-------|
| Files Changed | ${CHANGED_FILES} |
| Additions | +${ADDITIONS} |
| Deletions | -${DELETIONS} |
| Draft | ${DRAFT} |

### File Categories
$(echo "$CATEGORIES" | jq -r '.[] | "- **\(.category)**: \(.count) files"')

### File Types
$(echo "$FILE_TYPES" | jq -r '.[] | " - \`\(.type)\`: \(.count) files, \(.changes) changes"')

### Linked Issues
$(echo "$EXTRACTED_ISSUES" | jq -r '.[] | " - #\(.issue) (from PR body)"' 2>/dev/null || echo "_None detected_")

### Suggested Reviewers
$(echo "$SUGGESTED_REVIEWERS" | jq -r '[.[].owner] | unique | .[] | "- @\(.)"' 2>/dev/null || echo "_Auto-detected from CODEOWNERS_")

---
_Generated by [heretek-actions/pr-summary](https://github.com/Heretek-AI/heretek-actions)_
EOCOMMENT
  )

  gh api "repos/${owner}/${repo}/issues/${PR_NUMBER}/comments" \
    --field body="${COMMENT}" > /dev/null 2>&1 || true
fi

echo "status=success" >> "$GITHUB_OUTPUT"
echo "summary=PR #${PR_NUMBER}: ${SUMMARY}" >> "$GITHUB_OUTPUT"
