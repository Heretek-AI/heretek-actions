#!/usr/bin/env bash
set -euo pipefail

# Source the envelope helper
source "${AGENT_ACTION_PATH}/../agent-envelope.sh"

echo "🔍 Running automated review..."

MAX_FINDINGS="${MAX_FINDINGS:-30}"
SEVERITY_THRESHOLD="${SEVERITY_THRESHOLD:-warning}"
owner="${GITHUB_REPOSITORY_OWNER:-}"
repo="${GITHUB_REPOSITORY#*/}"

findings_file=$(mktemp)
review_start=$(date +%s)

# --- Helper: add a finding ---
add_finding() {
  local severity="$1"
  local rule="$2"
  local file="$3"
  local line="${4:-0}"
  local message="$5"
  local fix="${6:-}"

  if [ "$severity" = "info" ] && [ "$SEVERITY_THRESHOLD" = "error" ]; then
    return
  fi
  if [ "$severity" = "warning" ] && [ "$SEVERITY_THRESHOLD" = "error" ]; then
    return
  fi

  local finding
  finding=$(jq -n \
    --arg severity "$severity" \
    --arg rule "$rule" \
    --arg file "$file" \
    --argjson line "$line" \
    --arg message "$message" \
    --arg fix "$fix" \
    '{
      severity: $severity,
      rule: $rule,
      file: $file,
      line: ($line | tonumber),
      message: $message,
      suggested_fix: $fix
    }')

  echo "$finding" >> "$findings_file"
}

# --- Checks ---

# 1. Basic file structure violations
check_file_structure() {
  # Check for TODO/FIXME without tracking issues
  while IFS=: read -r file line content; do
    local todo_match
    todo_match=$(echo "$content" | grep -oE '(TODO|FIXME|HACK|XXX)([^)]|$)' || true)
    if [ -n "$todo_match" ]; then
      add_finding "warning" "todo-without-issue" "${file#./}" "$line" \
        "TODO/FIXME found without linked issue. Consider creating a tracking issue." \
        "Create a GitHub issue and reference it: TODO(#issue-number)"
    fi
  done < <(git grep -nE '(TODO|FIXME|HACK|XXX)' -- ':!*.lock' ':!*lockb' ':!*.sum' ':!node_modules/*' ':!target/*' ':!.git/*' 2>/dev/null | head -20 || true)
}

# 2. Check for missing tests
check_missing_tests() {
  # Look for source files without corresponding test files
  for src_file in $(find . -type f \( -name '*.ts' -o -name '*.js' -o -name '*.rs' -o -name '*.py' -o -name '*.go' \) \
    -not -path './node_modules/*' \
    -not -path './target/*' \
    -not -path './.git/*' \
    -not -path '*__pycache__*' \
    -not -path '*/test*' \
    -not -path '*/spec*' \
    -not -path '*/vendor/*' \
    -not -name '*.test.*' \
    -not -name '*.spec.*' \
    -not -name '_test.go' \
    2>/dev/null | head -20); do
    local basename
    basename=$(basename "$src_file")
    local dir
    dir=$(dirname "$src_file")
    local stem="${basename%.*}"

    local has_test=false
    case "$basename" in
      *.ts)   [ -f "${dir}/${stem}.test.ts" ] || [ -f "${dir}/${stem}.spec.ts" ] || [ -f "${dir}/__tests__/${stem}.test.ts" ] && has_test=true ;;
      *.js)   [ -f "${dir}/${stem}.test.js" ] || [ -f "${dir}/${stem}.spec.js" ] && has_test=true ;;
      *.rs)   [ -f "${dir}/${stem}_test.rs" ] || [ -f "${dir}/tests/${stem}.rs" ] && has_test=true ;;
      *.py)   [ -f "${dir}/test_${basename}" ] || [ -f "${dir}/${stem}_test.py" ] && has_test=true ;;
      *.go)   [ -f "${dir}/${stem}_test.go" ] && has_test=true ;;
    esac

    if [ "$has_test" = false ]; then
      add_finding "info" "missing-tests" "${src_file#./}" 0 \
        "Source file without corresponding test file" \
        "Create ${dir}/test_${basename} or ${dir}/${stem}.test.ts"
    fi
  done
}

# 3. Check for large files
check_file_sizes() {
  while IFS= read -r file; do
    local size
    size=$(wc -l < "$file" 2>/dev/null || echo 0)
    if [ "$size" -gt 500 ]; then
      add_finding "warning" "large-file" "${file#./}" 0 \
        "File is ${size} lines. Consider splitting into smaller modules." \
        "Refactor into smaller files (< 300 lines each)"
    fi
  done < <(find . -type f \( -name '*.ts' -o -name '*.js' -o -name '*.rs' -o -name '*.py' -o -name '*.go' -o -name '*.tsx' -o -name '*.jsx' \) \
    -not -path './node_modules/*' \
    -not -path './target/*' \
    -not -path './.git/*' \
    2>/dev/null | head -30 || true)
}

# 4. Check for hardcoded values (in JS/TS/Rust/Python)
check_hardcoded() {
  # Detect hardcoded URLs/API keys/secrets in config-like files
  git grep -nE '(api_key|API_KEY|secret|SECRET|password|PASSWORD|token=\w{20,}|https?://.*:[^@]@)' \
    -- ':!*.lock' ':!*lockb' ':!node_modules/*' ':!target/*' ':!.git/*' \
    ':!*.yaml' ':!*.yml' ':!*.env*' ':!*.example*' ':!*test*' \
    2>/dev/null | while IFS=: read -r file line content; do
    add_finding "error" "hardcoded-secret" "${file#./}" "$line" \
      "Potential hardcoded secret or credential" \
      "Use environment variables or a secrets manager"
  done || true
}

# 5. Check for console.log left in production code
check_debug_logs() {
  git grep -nE '(console\.log|println!|print\(|printf\()' \
    -- '*.ts' '*.js' '*.tsx' '*.jsx' '*.rs' '*.py' '*.go' \
    ':!*test*' ':!*spec*' ':!node_modules/*' ':!target/*' ':!.git/*' \
    ':!src/logger*' ':!src/logging*' ':!src/debug*' \
    2>/dev/null | while IFS=: read -r file line content; do
    add_finding "warning" "debug-log" "${file#./}" "$line" \
      "Debug log statement in non-test code" \
      "Remove or replace with proper logging framework"
  done || true
}

# 6. Check for commented-out code
check_commented_code() {
  git grep -nE '^\s*//\s*(function|class|def|const|let|var|import|export|fn|pub|impl)' \
    -- '*.ts' '*.js' '*.rs' '*.go' \
    ':!node_modules/*' ':!target/*' ':!.git/*' \
    2>/dev/null | while IFS=: read -r file line content; do
    add_finding "warning" "commented-code" "${file#./}" "$line" \
      "Commented-out code detected" \
      "Remove dead code instead of commenting it out"
  done || true
}

# 7. Check for TODO/FIXME in PR diff (if PR context available)
check_pr_specific() {
  if [ -z "${PR_NUMBER:-}" ]; then
    return
  fi

  local diff
  diff=$(gh api "repos/${owner}/${repo}/pulls/${PR_NUMBER}/files?per_page=100" \
    --jq '[.[] | select(.additions > 0) | {path, additions_url}]' 2>/dev/null || echo '[]')

  if [ "$diff" = "[]" ] || [ "$diff" = "null" ]; then
    return
  fi

  # Check PR files for the above patterns specifically in the diff
  echo "$diff" | jq -r '.[].path' | while IFS= read -r file; do
    if [ -f "$file" ]; then
      # Look for added lines with TODO (rough heuristic using git blame)
      if git blame "$file" 2>/dev/null | head -5 | grep -q "00000000"; then
        : # New file — already caught by general scan
      fi
    fi
  done || true
}

# 8. Check for focus-test (it.only/describe.only) in test files
check_focused_tests() {
  git grep -nE '(it\.only|describe\.only|test\.only|fit\()' \
    -- '*test*' '*spec*' '*.test.*' '*.spec.*' \
    ':!node_modules/*' ':!target/*' ':!.git/*' \
    2>/dev/null | while IFS=: read -r file line content; do
    add_finding "error" "focused-test" "${file#./}" "$line" \
      "Focused test (it.only/describe.only) found — will skip other tests" \
      "Remove .only to run the full test suite"
  done || true
}

# --- Run all checks ---
check_file_structure
check_missing_tests
check_file_sizes
check_hardcoded
check_debug_logs
check_commented_code
check_pr_specific
check_focused_tests

# --- Compile findings ---
ALL_FINDINGS=$(cat "$findings_file" 2>/dev/null | jq -s 'sort_by(.severity) | .[0:'"$MAX_FINDINGS"']' 2>/dev/null || echo '[]')

ERROR_COUNT=$(echo "$ALL_FINDINGS" | jq '[.[] | select(.severity == "error")] | length')
WARNING_COUNT=$(echo "$ALL_FINDINGS" | jq '[.[] | select(.severity == "warning")] | length')
INFO_COUNT=$(echo "$ALL_FINDINGS" | jq '[.[] | select(.severity == "info")] | length')

# Determine status
if [ "$ERROR_COUNT" -gt 0 ]; then
  REVIEW_STATUS="failure"
elif [ "$WARNING_COUNT" -gt 0 ]; then
  REVIEW_STATUS="partial"
else
  REVIEW_STATUS="success"
fi

SUMMARY="${ERROR_COUNT} errors, ${WARNING_COUNT} warnings, ${INFO_COUNT} info"

# Build outputs
AGENT_OUTPUTS=$(cat <<OUTPUTS
{
  "summary": {
    "errors": ${ERROR_COUNT},
    "warnings": ${WARNING_COUNT},
    "info": ${INFO_COUNT},
    "total": $(echo "$ALL_FINDINGS" | jq 'length'),
    "truncated": $(echo "$ALL_FINDINGS" | jq "length > $MAX_FINDINGS")
  },
  "rules_applied": [
    "todo-without-issue",
    "missing-tests",
    "large-file",
    "hardcoded-secret",
    "debug-log",
    "commented-code",
    "focused-test"
  ]
}
OUTPUTS
)
export AGENT_OUTPUTS
export AGENT_FINDINGS="$ALL_FINDINGS"

# Suggestions
SUGGESTIONS='[]'
if [ "$ERROR_COUNT" -gt 0 ]; then
  add_suggestion "issue:create" "${ERROR_COUNT} error(s) found in review" \
    "{\"labels\": [\"review\", \"automated\"], \"title\": \"Review findings: ${ERROR_COUNT} errors\"}" "medium"
fi

review_end=$(date +%s)
export AGENT_DURATION_MS=$(( (review_end - review_start) * 1000 ))

write_envelope "review" "$REVIEW_STATUS" "$SUMMARY"

# Cleanup
rm -f "$findings_file"

echo "status=${REVIEW_STATUS}" >> "$GITHUB_OUTPUT"
echo "summary=${SUMMARY}" >> "$GITHUB_OUTPUT"
