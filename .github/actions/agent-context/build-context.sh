#!/usr/bin/env bash
set -euo pipefail

# Source the envelope helper
source "${AGENT_ACTION_PATH}/../agent-envelope.sh"

# Determine repo structure
MAX_DEPTH="${MAX_DEPTH:-3}"
INCLUDE_TESTS="${INCLUDE_TESTS:-false}"

# Detect stack
detect_stack() {
  local stack=()
  local manager=""
  local pm=""
  local workspaces=()

  if [ -f "Cargo.toml" ]; then
    stack+=("rust")
    # Detect workspace members
    if grep -q "\[workspace\]" Cargo.toml 2>/dev/null; then
      while IFS= read -r member; do
        workspaces+=("$member")
      done < <(grep -A100 "\[workspace\]" Cargo.toml | grep "members" | sed 's/.*=\[//;s/\].*//;s/,/\n/g' | tr -d '" ' || true)
    fi
  fi

  if [ -f "package.json" ]; then
    local pm="npm"
    if [ -f "pnpm-lock.yaml" ]; then pm="pnpm"; fi
    if [ -f "yarn.lock" ]; then pm="yarn"; fi
    if [ -f "bun.lock" ] || [ -f "bun.lockb" ]; then pm="bun"; fi
    manager="${pm}"
    stack+=("javascript")

    # Detect framework
    if [ -f "next.config.js" ] || [ -f "next.config.mjs" ] || [ -f "next.config.ts" ]; then
      stack+=("nextjs")
    elif [ -f "nuxt.config.ts" ] || [ -f "nuxt.config.js" ]; then
      stack+=("nuxt")
    elif [ -f "astro.config.mjs" ] || [ -f "astro.config.ts" ]; then
      stack+=("astro")
    fi

    # Detect monorepo workspaces
    if grep -q '"workspaces"' package.json 2>/dev/null; then
      while IFS= read -r ws; do
        workspaces+=("$ws")
      done < <(jq -r '.workspaces[] // empty' package.json 2>/dev/null || true)
    fi
  fi

  if [ -f "pyproject.toml" ]; then
    stack+=("python")
    if command -v poetry &>/dev/null || grep -q "\[tool.poetry\]" pyproject.toml 2>/dev/null; then
      manager="poetry"
    elif [ -f "Pipfile" ]; then
      manager="pipenv"
    elif [ -f "requirements.txt" ]; then
      manager="pip"
    elif [ -f "uv.lock" ]; then
      manager="uv"
    fi
  fi

  if [ -f "Dockerfile" ] || [ -f "docker-compose.yml" ] || [ -f "compose.yml" ]; then
    stack+=("docker")
  fi

  if [ -f ".github/workflows/release.yml" ] || ls .github/workflows/*release* &>/dev/null 2>&1; then
    stack+=("release")
  fi

  # Output
  echo "STACK=$(echo "${stack[@]}" | jq -Rc 'split(" ") | map(select(length > 0))')" >> "$GITHUB_ENV"
  echo "PACKAGE_MANAGER=${manager}" >> "$GITHUB_ENV"
  echo "WORKSPACES=$(echo "${workspaces[@]}" | jq -Rc 'split(" ") | map(select(length > 0))')" >> "$GITHUB_ENV"
}

# Scan directory structure
scan_structure() {
  local depth="$1"
  local outfile="$2"

  find . -maxdepth "$depth" -type d \
    -not -path './.git/*' \
    -not -path './node_modules/*' \
    -not -path './target/*' \
    -not -path './.venv/*' \
    -not -path './__pycache__/*' \
    -not -path './.next/*' \
    -not -path './dist/*' \
    -not -path './build/*' \
    -not -path './.claude/*' \
    2>/dev/null | sort > "${outfile}.dirs"

  find . -maxdepth "$depth" -type f \
    -not -path './.git/*' \
    -not -path './node_modules/*' \
    -not -path './target/*' \
    -not -path './.venv/*' \
    -not -path './__pycache__/*' \
    -not -path './.next/*' \
    -not -path './dist/*' \
    -not -path './build/*' \
    -not -path './.claude/*' \
    -not -name '*.lock' \
    -not -name '*.sum' \
    2>/dev/null | sort > "${outfile}.files"
}

# Detect hooks config
detect_hooks() {
  local hooks_framework=""
  local hooks_config=""

  if [ -f ".pre-commit-config.yaml" ]; then
    hooks_framework="pre-commit"
    hooks_config=".pre-commit-config.yaml"
  elif [ -f ".husky/pre-commit" ]; then
    hooks_framework="husky"
    hooks_config=".husky/"
  elif [ -f "lefthook.yml" ] || [ -f "lefthook.yaml" ]; then
    hooks_framework="lefthook"
    hooks_config="lefthook.yml"
  fi

  echo "HOOKS_FRAMEWORK=${hooks_framework}" >> "$GITHUB_ENV"
  echo "HOOKS_CONFIG=${hooks_config}" >> "$GITHUB_ENV"
}

# Query GitHub for repo metadata (issues, PRs, labels)
query_github() {
  local owner repo
  owner="${GITHUB_REPOSITORY_OWNER:-}"
  repo="${GITHUB_REPOSITORY#*/}"

  if [ -z "$owner" ] || [ -z "$repo" ] || [ -z "$GH_TOKEN" ]; then
    echo "NO_GITHUB_DATA=true" >> "$GITHUB_ENV"
    return
  fi

  # Recent merged PRs (last 5)
  RECENT_PRS=$(gh api "repos/${owner}/${repo}/pulls?state=closed&per_page=5&sort=updated&direction=desc" \
    --jq '[.[] | select(.merged_at != null) | {title, number, merged_at, labels: [.labels[].name]}] | .[0:5]' 2>/dev/null || echo "[]")

  # Open issues count
  OPEN_ISSUES=$(gh api "repos/${owner}/${repo}/issues?state=open&per_page=1&filter=all" \
    --jq '[.[]] | length' 2>/dev/null || echo "0")

  # Open PRs count
  OPEN_PRS=$(gh api "repos/${owner}/${repo}/pulls?state=open&per_page=1" \
    --jq '[.[]] | length' 2>/dev/null || echo "0")

  # Labels
  LABELS=$(gh api "repos/${owner}/${repo}/labels?per_page=50" \
    --jq '[.[].name]' 2>/dev/null || echo "[]")

  # Code owners
  CODEOWNERS=$(cat .github/CODEOWNERS 2>/dev/null || echo "")

  echo "RECENT_PRS=${RECENT_PRS}" >> "$GITHUB_ENV"
  echo "OPEN_ISSUES=${OPEN_ISSUES}" >> "$GITHUB_ENV"
  echo "OPEN_PRS=${OPEN_PRS}" >> "$GITHUB_ENV"
  echo "LABELS=${LABELS}" >> "$GITHUB_ENV"
  echo "CODEOWNERS<<EOF" >> "$GITHUB_ENV"
  echo "${CODEOWNERS}" >> "$GITHUB_ENV"
  echo "EOF" >> "$GITHUB_ENV"
  echo "NO_GITHUB_DATA=false" >> "$GITHUB_ENV"
}

# --- Main ---
echo "🔍 Building repo context..."

# Initialize defaults before calling detection functions
# (these functions write to GITHUB_ENV for downstream steps,
# but we need local copies here)
STACK="[]"
PACKAGE_MANAGER=""
WORKSPACES="[]"
HOOKS_FRAMEWORK=""
HOOKS_CONFIG=""
NO_GITHUB_DATA="true"
OPEN_ISSUES=0
OPEN_PRS=0
RECENT_PRS="[]"
LABELS="[]"

detect_stack
detect_hooks
query_github

# Build structure
structure_tmp=$(mktemp -d)
scan_structure "$MAX_DEPTH" "${structure_tmp}/structure"

# Package context into outputs
TOP_FILES=$(head -30 "${structure_tmp}/structure.files" 2>/dev/null | jq -Rc '[inputs]' 2>/dev/null || echo "[]")
TOP_DIRS=$(head -30 "${structure_tmp}/structure.dirs" 2>/dev/null | jq -Rc '[inputs]' 2>/dev/null || echo "[]")

AGENT_OUTPUTS=$(cat <<'OUTPUTS' | envsubst 2>/dev/null || cat
{
  "name": "${GITHUB_REPOSITORY#*/}",
  "owner": "${GITHUB_REPOSITORY_OWNER:-}",
  "default_branch": "${GITHUB_BASE_REF:-main}",
  "stack": ${STACK},
  "package_manager": "${PACKAGE_MANAGER}",
  "workspaces": ${WORKSPACES},
  "hooks": {
    "framework": "${HOOKS_FRAMEWORK}",
    "config": "${HOOKS_CONFIG}"
  },
  "structure": {
    "files": ${TOP_FILES},
    "directories": ${TOP_DIRS}
  },
  "issues": {
    "open": ${OPEN_ISSUES:-0},
    "open_prs": ${OPEN_PRS:-0}
  },
  "recent_prs": ${RECENT_PRS:-"[]"},
  "labels": ${LABELS:-"[]"}
}
OUTPUTS
)
export AGENT_OUTPUTS

# Determine overall summary
SUMMARY="Repo: ${GITHUB_REPOSITORY} | Stack: ${STACK} | Open Issues: ${OPEN_ISSUES:-0} | Open PRs: ${OPEN_PRS:-0}"

# Save context to .claude/context.json for Claude users
mkdir -p .claude
echo "$AGENT_OUTPUTS" > .claude/context.json

write_envelope "agent-context" "success" "$SUMMARY"

# Cleanup
rm -rf "$structure_tmp"
