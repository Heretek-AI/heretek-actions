# Heretek Actions

> Reusable GitHub Actions and workflows for **agent-driven development**.
> Every action produces a standardized JSON envelope at `.agent/output.json` for easy agent consumption.

[![Agent Context](https://github.com/Heretek-AI/heretek-actions/actions/workflows/agent-context.yml/badge.svg)](https://github.com/Heretek-AI/heretek-actions/actions/workflows/agent-context.yml)
[![Pre-commit CI](https://github.com/Heretek-AI/heretek-actions/actions/workflows/pre-commit-ci.yml/badge.svg)](https://github.com/Heretek-AI/heretek-actions/actions/workflows/pre-commit-ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

---

## Features

- **🤖 Agent-Facing Tooling** — Actions designed for AI agents to parse and act upon: PR summaries, issue triage, repo context, check status, and automated review
- **🔄 Multi-Language CI** — Auto-detect your stack and run the right checks for Rust, JavaScript/TypeScript, Python, Docker, and web projects
- **📋 Pre-commit Hooks** — Universal hook configuration via the Python `pre-commit` framework (no Node dependency)
- **🚀 Universal Release** — Release to Docker, Flatpak, npm, or GitHub releases from a single workflow
- **📦 Standardized Output** — Every action writes `.agent/output.json` following a [shared schema](.agent/schema.json) — **one file for agents to read**

---

## Quick Start

### Agent Tooling (30 seconds)

Add this workflow to your repo:

```yaml
# .github/workflows/agent-tools.yml
name: Agent Tools
on:
  push:
    branches: [main, master]
  issues:
    types: [opened]
  pull_request:
    types: [opened, synchronize]

jobs:
  context:
    uses: Heretek-AI/heretek-actions/.github/workflows/agent-context.yml@v1
  triage:
    uses: Heretek-AI/heretek-actions/.github/workflows/issue-triage.yml@v1
  pr-summary:
    uses: Heretek-AI/heretek-actions/.github/workflows/pr-summary.yml@v1
```

Then any **AI agent** can read `.agent/output.json` to understand your repo, triaged issues, and PR summaries — in one file.

### AI-Powered Code Review (Open Code Review)

Add AI-powered code review that runs on every PR:

```yaml
name: PR Review
on:
  pull_request_target:
    types: [opened, synchronize, reopened]
jobs:
  review:
    uses: Heretek-AI/heretek-actions/.github/workflows/ocr-review.yml@v1
    secrets:
      ocr_llm_url: ${{ secrets.OCR_LLM_URL }}
      ocr_llm_token: ${{ secrets.OCR_LLM_TOKEN }}
```

You can also trigger a full codebase scan manually:

```yaml
name: Codebase Scan
on: workflow_dispatch
jobs:
  scan:
    uses: Heretek-AI/heretek-actions/.github/workflows/ocr-scan.yml@v1
    secrets:
      ocr_llm_url: ${{ secrets.OCR_LLM_URL }}
      ocr_llm_token: ${{ secrets.OCR_LLM_TOKEN }}
```

**Requirements:** Configure [secrets/vars](#open-code-review-configuration) with your LLM API credentials.

### CI Checks

```yaml
name: CI
on: [pull_request]
jobs:
  check:
    uses: Heretek-AI/heretek-actions/.github/workflows/check.yml@v1
```

Auto-detects your language (Rust, JS/TS, Python, Docker) and runs the appropriate checks.

### Pre-commit Hooks

```bash
pip install pre-commit
pre-commit install
```

Copy the [`.pre-commit-config.yaml`](.pre-commit-config.yaml) from this repo, or reference it:

```yaml
# .pre-commit-config.yaml
repos:
  - repo: https://github.com/Heretek-AI/heretek-actions
    rev: v1
    hooks:
      - id: agent-context
        stages: [manual]
```

---

## Agent-Facing Actions

All agent actions emit `.agent/output.json` with the [Standard Envelope](#agent-integration). An agent reads one file and knows what to do.

| Action | Trigger | What it does | For Agents |
|--------|---------|-------------|------------|
| [`agent-context`](.github/actions/agent-context/) | push, dispatch | Scans repo structure, detects stack, queries GitHub API | Start here — agent reads context in seconds |
| [`pr-summary`](.github/actions/pr-summary/) | pull_request | Analyzes PR diff, categorizes files, links issues, suggests reviewers | Agent creates PR body + structured JSON |
| [`issue-triage`](.github/actions/issue-triage/) | issues.opened | Classifies issues, applies labels, detects duplicates | Agent reads classification, responds or closes |
| [`check-status`](.github/actions/check-status/) | check_run (via workflow_call) | Watches all CI checks, produces merged status | Agent knows when to merge or investigate |
| [`review`](.github/actions/review/) | pull_request | Lightweight structural analysis (TODOs, missing tests, hardcoded secrets, debug logs, focused tests) | Agent gets findings array and creates issues |
| [`ocr-review`](.github/workflows/ocr-review.yml) | pull_request_target | AI-powered PR review via Open Code Review (LLM-backed) | Agent reads findings and suggested issues |
| [`ocr-scan`](.github/workflows/ocr-scan.yml) | workflow_dispatch | Full codebase scan via Open Code Review | Agent reads findings across all files |

### `agent-context` — Understand Any Repo Fast

```yaml
- uses: Heretek-AI/heretek-actions/.github/actions/agent-context@v1
```

**Output** (in `.agent/output.json`):
```json
{
  "outputs": {
    "name": "my-project",
    "stack": ["rust", "javascript"],
    "package_manager": "pnpm",
    "workspaces": ["crates/*", "packages/*"],
    "hooks": { "framework": "pre-commit", "config": ".pre-commit-config.yaml" },
    "issues": { "open": 12, "open_prs": 3 },
    "labels": ["bug", "enhancement", "question"]
  },
  "suggestions": [
    { "type": "none", "reason": "Repo context collected" }
  ]
}
```

Also writes `.claude/context.json` for Claude Code users.

### `pr-summary` — Structured PR Analysis

```yaml
- uses: Heretek-AI/heretek-actions/.github/actions/pr-summary@v1
  with:
    post-comment: "true"
```

**Output** includes file statistics, change categories, linked issues, and suggested reviewers.

### `issue-triage` — Auto-Organize Issues

```yaml
- uses: Heretek-AI/heretek-actions/.github/actions/issue-triage@v1
  with:
    auto-label: "true"
    duplicate-threshold: "0.7"
```

Detects issue types (bug, feature, question, docs, security, performance), applies labels, and flags potential duplicates via word-overlap similarity.

### `check-status` — CI Dashboard for Agents

```yaml
- uses: Heretek-AI/heretek-actions/.github/actions/check-status@v1
  with:
    wait-for-completion: "600"
```

Polls check runs until complete, then tells the agent the merged result and whether to merge.

### `review` — Lightweight Automated Review

```yaml
- uses: Heretek-AI/heretek-actions/.github/actions/review@v1
```

Scans for: TODO/FIXME without issues, missing test files, large files (>500 lines), hardcoded secrets, debug logs, commented-out code, and focused tests (`it.only`, `describe.only`).

---

## CI Composite Actions

| Action | Stack | What It Runs | Opt-Ins |
|--------|-------|-------------|---------|
| [`rust-ci`](.github/actions/rust-ci/) | 🦀 Rust | `cargo fmt`, `cargo clippy`, `cargo test` | coverage (`cargo-llvm-cov`), audit (`cargo-audit`) |
| [`js-ci`](.github/actions/js-ci/) | 🟨 JS/TS | lint, typecheck (tsc --noEmit), test | — |
| [`python-ci`](.github/actions/python-ci/) | 🐍 Python | lint (ruff), typecheck (mypy), test (pytest) | — |

### `rust-ci` Example

```yaml
- uses: Heretek-AI/heretek-actions/.github/actions/rust-ci@v1
  with:
    toolchain: nightly
    working-directory: ./crates/my-crate
    enable-coverage: "true"
    enable-audit: "true"
```

### `js-ci` Example

```yaml
- uses: Heretek-AI/heretek-actions/.github/actions/js-ci@v1
  with:
    node-version: "22"
    package-manager: pnpm
```

Auto-detects pnpm, yarn, bun, or npm from lock files.

### `python-ci` Example

```yaml
- uses: Heretek-AI/heretek-actions/.github/actions/python-ci@v1
  with:
    python-version: "3.12"
```

---

## Workflows

### `check.yml` — Universal CI Orchestrator

```yaml
jobs:
  check:
    uses: Heretek-AI/heretek-actions/.github/workflows/check.yml@v1
    with:
      enable-coverage: "true"
      enable-audit: "true"
```

Auto-detects languages in the repo and runs the matching CI actions. Configure with inputs to override detection.

### `release.yml` — Universal Release

```yaml
jobs:
  release:
    uses: Heretek-AI/heretek-actions/.github/workflows/release.yml@v1
    with:
      release-type: docker
      version: v1.2.3
      dockerfile: ./Dockerfile
      docker-image-name: my-org/my-app
    secrets:
      repo_token: ${{ secrets.GITHUB_TOKEN }}
```

Supports `docker`, `flatpak`, `npm`, and `github-release` as release types.

### `ocr-review.yml` — AI-Powered PR Review

```yaml
jobs:
  review:
    uses: Heretek-AI/heretek-actions/.github/workflows/ocr-review.yml@v1
    secrets:
      ocr_llm_url: ${{ secrets.OCR_LLM_URL }}
      ocr_llm_token: ${{ secrets.OCR_LLM_TOKEN }}
```

Uses [Open Code Review](https://open-codereview.ai) to analyze pull requests with an LLM. Comments inline, produces `.agent/output.json`. Also supports re-triggering via `/open-code-review` or `@open-code-review` comments on the PR. For `workflow_call`, pass secrets as shown above.

**Required secrets:** `ocr_llm_url`, `ocr_llm_token`

### `ocr-scan.yml` — Full Codebase Scan

```yaml
jobs:
  scan:
    uses: Heretek-AI/heretek-actions/.github/workflows/ocr-scan.yml@v1
    secrets:
      ocr_llm_url: ${{ secrets.OCR_LLM_URL }}
      ocr_llm_token: ${{ secrets.OCR_LLM_TOKEN }}
    with:
      scan-path: "."
      ocr-use-anthropic: "true"
```

Triggered manually (`workflow_dispatch`) or via `workflow_call`. Scans the entire repo (or a sub-path) and reports findings in `.agent/output.json`. Supports opt-in issue creation from findings.

---

## Open Code Review Configuration

Both OCR workflows require LLM credentials. Set these as [GitHub secrets/variables](https://docs.github.com/en/actions/security-guides/using-secrets-in-github-actions):

| Secret/Variable | Type | Description | Example |
|----------------|------|-------------|---------|
| `OCR_LLM_URL` | secret | LLM API endpoint | `https://api.anthropic.com/v1/messages` |
| `OCR_LLM_TOKEN` | secret | API authentication token | `sk-ant-...` |
| `OCR_LLM_MODEL` | **secret** or variable | Default LLM model (secret recommended for org-wide defaults) | `claude-sonnet-4-20250514` |
| `OCR_LLM_USE_ANTHROPIC` | variable | Protocol selection | `true` (Anthropic) or `false` (OpenAI) |

**Model resolution order:** `secrets.ocr_llm_model` → `inputs.ocr-llm-model` → `vars.OCR_LLM_MODEL` → built-in default (`claude-sonnet-4-20250514`). Set `OCR_LLM_MODEL` as a GitHub secret to configure the model once for your org without exposing it in workflow files.

Pass them in your workflow:

```yaml
jobs:
  review:
    uses: Heretek-AI/heretek-actions/.github/workflows/ocr-review.yml@v1
    secrets:
      ocr_llm_url: ${{ secrets.OCR_LLM_URL }}
      ocr_llm_token: ${{ secrets.OCR_LLM_TOKEN }}
```

When referencing via `workflow_call`, the secret names use underscores (`ocr_llm_url`, `ocr_llm_token`, `ocr_llm_model`); the GitHub UI secrets use uppercase underscore names (`OCR_LLM_URL`, `OCR_LLM_TOKEN`, `OCR_LLM_MODEL`). You only need to configure `OCR_LLM_URL` and `OCR_LLM_TOKEN` in your repo settings (and optionally `OCR_LLM_MODEL` for a default model), then pass them via `secrets:` mapping in the workflow.

---

## Agent Integration

### The Standard Envelope

Every Heretek Action writes `.agent/output.json` following this schema:

```json
{
  "agent_action": "pr-summary",
  "version": "1.0",
  "status": "success",
  "summary": "3 files changed, 45 additions, 12 deletions",
  "outputs": { /* action-specific structured data */ },
  "suggestions": [
    {
      "type": "issue:create",
      "reason": "2 lint errors found in src/main.ts",
      "data": { "labels": ["lint", "automated"] },
      "priority": "medium"
    }
  ],
  "checks": [],
  "findings": [],
  "release": null,
  "created_at": "2026-07-30T12:00:00Z",
  "repository": {
    "owner": "Heretek-AI",
    "repo": "heretek-actions",
    "sha": "abc123...",
    "ref": "refs/heads/main"
  }
}
```

### Agent Reading Pattern

```python
import json

with open(".agent/output.json") as f:
    envelope = json.load(f)

if envelope["status"] == "success":
    print(f"✅ {envelope['summary']}")
else:
    print(f"❌ {envelope['summary']}")

for suggestion in envelope.get("suggestions", []):
    if suggestion["type"] == "issue:create":
        # Create GitHub issue
        create_issue(**suggestion["data"])
    elif suggestion["type"] == "pr:merge":
        # Merge the PR
        merge_pr(suggestion["data"]["pr_number"])
```

### Suggestion Types

| Type | Meaning | Agent Action |
|------|---------|-------------|
| `issue:create` | Finding worth tracking | Create a GitHub issue |
| `issue:label` | Issue needs a label | Add label to issue |
| `issue:close` | Probable duplicate | Close or escalate |
| `pr:merge` | All checks passed | Merge the PR |
| `pr:review_request` | Large/complex change | Request human review |
| `comment:post` | Needs communication | Post a comment |
| `release:create` | Release completed | Notify stakeholders |
| `none` | Informational only | No action needed |

---

## Pre-commit Hooks

This repo provides a universal [`.pre-commit-config.yaml`](.pre-commit-config.yaml) that works across languages:

```bash
# Install
pip install pre-commit
pre-commit install

# Run on all files
pre-commit run --all-files
```

**What's included:**
- **Universal**: trailing whitespace, EOF fixer, YAML/JSON/TOML validation, merge conflict detection, private key detection
- **Security**: `detect-secrets` with baseline support
- **Rust**: `cargo check`, `clippy`, `fmt`
- **JS/TS**: `eslint`, `prettier`
- **Python**: `ruff`, `mypy`
- **Shell**: `shellcheck`
- **Docker**: `hadolint`
- **Commits**: Conventional Commits enforcement

Language-specific hooks are staged as `manual` — only run if the tooling is present.

---

## Local Development

```bash
# Clone the repo
git clone https://github.com/Heretek-AI/heretek-actions
cd heretek-actions

# Setup pre-commit
pip install pre-commit
pre-commit install

# Validate action.yml files
actionlint
```

### Project Structure

```
heretek-actions/
├── .agent/
│   └── schema.json
├── .github/
│   ├── actions/
│   │   ├── agent-envelope.sh     # Shared envelope writer
│   │   ├── agent-context/
│   │   ├── pr-summary/
│   │   ├── issue-triage/
│   │   ├── check-status/
│   │   ├── review/
│   │   ├── rust-ci/
│   │   ├── js-ci/
│   │   ├── python-ci/
│   │   └── release/
│   ├── workflows/
│   │   ├── agent-context.yml
│   │   ├── pr-summary.yml
│   │   ├── issue-triage.yml
│   │   ├── check-status.yml
│   │   ├── review.yml
│   │   ├── check.yml
│   │   ├── pre-commit-ci.yml
│   │   └── release.yml
│   └── CODEOWNERS
├── .pre-commit-config.yaml
├── LICENSE
└── README.md
```

---

## Roadmap

- [x] **Phase 1**: Foundation — repo structure, schema, README shell
- [x] **Phase 2**: Agent-facing actions — context, pr-summary, issue-triage, check-status, review
- [x] **Phase 3**: Pre-commit hooks — universal `.pre-commit-config.yaml`, CI workflow
- [x] **Phase 4**: CI actions — rust-ci, js-ci, python-ci composite actions
- [x] **Phase 5**: Universal check.yml orchestrator with auto-detect
- [x] **Phase 6**: Universal release workflow
- [x] **Phase 7**: Documentation — README, per-action docs, agent integration guide
- [ ] Live testing on reference repos
- [ ] GitHub Marketplace listing
- [ ] v1 release tag

---

## License

MIT — see [LICENSE](LICENSE)

---

Built for agents, by agents. 🤖
