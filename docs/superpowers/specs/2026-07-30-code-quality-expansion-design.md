# Code Quality Expansion Design

**Date:** 2026-07-30
**Status:** Draft
**Author:** AI (brainstorming session)
**Project:** Heretek Actions — code quality tooling expansion

---

## Summary

Expand Heretek Actions from the current pre-commit + per-language CI + basic review
into a comprehensive code quality platform with unified linting, coverage enforcement,
workflow validation, security scanning, quality gates, and developer experience
improvements, organized in three priority tiers.

All additions follow the existing patterns:
- Composite actions emit `.agent/output.json` via `agent-envelope.sh`
- Workflows are callable via `workflow_call`
- Exported configs (lefthook, dependabot) live at the repo root
- Each action is independently adoptable and versioned

---

## Tier 1 — 🔴 Foundation Gaps (Highest Impact)

### 1.1 MegaLinter Unified Lint Action

**Action:** `.github/actions/lint-ultimate/action.yml`

A single composite action wrapping [MegaLinter](https://megalinter.io/) (or
[Super-Linter](https://github.com/super-linter/super-linter) as an alternative),
analyzing 40+ languages, 22 formats, IaC, and config files in one step.

**Inputs:**
| Name | Type | Default | Description |
|------|------|---------|-------------|
| `linter` | string | `megalinter` | `megalinter` or `super-linter` |
| `linter-version` | string | `v7` | Version tag for the chosen linter suite |
| `config-file` | string | `.mega-linter.yml` | Path to MegaLinter config (megalinter only) |
| `upload-artifacts` | bool | `true` | Upload lint reports as artifacts |
| `github-token` | string | `${{ github.token }}` | GitHub token |

**Steps:**
1. Checkout code
2. Run MegaLinter via `oxsecurity/megalinter/flavors/all@v7`
3. Parse `megalinter-report.json` into standard findings and checks
4. Call `build-envelope.sh` from `agent-envelope.sh`

**Envelope mapping:**
- Each linter category → `checks[]` entry (MARKDOWN, PYTHON_RUFF, etc.)
- Each individual finding → `findings[]` entry with severity/file/line/message
- Suggestions for block-level errors generate `issue:create` suggestions

**Build-envelope script:** `.github/actions/lint-ultimate/build-envelope.sh`

Parses the MegaLinter JSON report and maps to the standard envelope format.
Handles the shape differences between MegaLinter (nested by linter) and
Super-Linter (flat file-list).

### 1.2 Code Coverage Upload & Gates

**Action:** `.github/actions/coverage/action.yml`

Collects coverage reports from any framework and uploads to a coverage service
or enforces thresholds.

**Inputs:**
| Name | Type | Default | Description |
|------|------|---------|-------------|
| `action` | string | `both` | `upload`, `gate`, or `both` |
| `format` | string | `auto` | `auto`, `lcov`, `cobertura`, `clover`, `jacoco` |
| `threshold` | number | `80` | Minimum coverage % (gate mode) |
| `threshold-diff` | number | `""` | Max allowed % drop vs default branch |
| `upload-method` | string | `github-code-quality` | `github-code-quality`, `codecov`, `coveralls` |

**Behavior:**
- Auto-detects coverage artifacts by scanning for known filenames
- Upload mode: sends report to the chosen service
- Gate mode: parses the report and compares against threshold
- Uses existing `cargo-llvm-cov` / `pytest-cov` / `vitest --coverage` outputs

**Integration with existing CI actions:**
- `rust-ci`: `enable-coverage` input already exists, wires through to this action
- `js-ci`: New `enable-coverage` input added
- `python-ci`: New `enable-coverage` input added

**File:** `.github/actions/coverage/enforce-coverage.sh`

Shell script that reads a Cobertura/lcov file, computes overall coverage percentage,
compares against threshold, and writes the envelope.

### 1.3 actionlint Workflow Validator

**Action:** `.github/actions/actionlint/action.yml`

Validates all `.github/workflows/*.yml` files using
[rhysd/actionlint](https://github.com/rhysd/actionlint) with reviewdog integration.

**Inputs:**
| Name | Type | Default | Description |
|------|------|---------|-------------|
| `severity` | string | `error` | Minimum severity to report |
| `reviewdog` | bool | `true` | Post findings as PR review comments |
| `reviewdog-reporter` | string | `github-pr-review` | `github-pr-review` or `github-check` |
| `extra-flags` | string | `""` | Additional actionlint flags |

**Steps:**
1. Install actionlint binary (cached via `@actions/tool-cache`)
2. Run `actionlint` over `.github/workflows/` with problem matchers
3. Pipe output through reviewdog for PR annotations
4. Parse results into findings array for envelope

**Envelope:**
- Findings use `rule: "actionlint"`, file path, line number, and the actionlint error message
- Each workflow file is a separate `checks[]` entry

### 1.4 CodeQL Security & Quality Scanning

**Workflow:** `.github/workflows/codeql-analysis.yml`

Standard CodeQL init → analyze → envelope pipeline.

**Inputs:**
| Name | Type | Default | Description |
|------|------|---------|-------------|
| `languages` | string | `auto` | Languages to analyze |
| `mode` | string | `both` | `security`, `quality`, or `both` |
| `severity-threshold` | string | `high` | Minimum severity for findings |
| `upload-sarif` | bool | `true` | Upload SARIF results to GitHub |

**Steps:**
1. `github/codeql-action/init@v3` with languages
2. `github/codeql-action/analyze@v3` — produces SARIF
3. Parse SARIF output into findings array
4. Call `build-envelope.sh`

**Integration:** This is a workflow, not a composite action, because CodeQL requires
its own job lifecycle (init must run before build, analyze after). The envelope
step reads the `results.sarif` artifact.

---

## Tier 2 — 🟡 Developer Experience & Process Improvements

### 2.1 Lefthook Alternative Configuration

**File:** `lefthook.yml`

A zero-dependency git hooks configuration mirroring `.pre-commit-config.yaml`
capabilities in Lefthook's native format.

**Structure:**
- `pre-commit` parallel commands match pre-commit hooks 1:1
- Universal hooks (trailing-whitespace, EOF, YAML, JSON, merge-conflict) enabled
- Language-specific hooks (eslint, ruff, clippy, hadolint) `skip: true` by default
- `commit-msg` hook enforces Conventional Commits via `@commitlint/cli`

**Action:** `.github/actions/lefthook-ci/action.yml`

Runs lefthook in CI (parallel to the existing `pre-commit-ci.yml`):
- Installs lefthook binary (Go, no deps)
- Runs `lefthook run --all`
- Parses output (colored, structured) into envelope checks
- Supports same `skip` flags as the config

### 2.2 Test Matrix / Parallel Sharding

**Action:** `.github/actions/test-matrix/action.yml`

Produces balanced parallel shards for test execution across multiple runners.

**Inputs:**
| Name | Type | Default | Description |
|------|------|---------|-------------|
| `framework` | string | `auto` | `auto`, `jest`, `playwright`, `vitest`, `pytest`, `cargo` |
| `shards` | number | `4` | Number of parallel shards |
| `timing-file` | string | `.agent/test-timings.json` | Previous run timing data |
| `flaky-retries` | number | `2` | Max retries per flaky test |

**Behavior:**
- Detects framework from lockfiles/config
- Outputs a JSON matrix for the calling workflow's `strategy.matrix` field
- Each shard receives `SHARD_INDEX` / `SHARD_COUNT` env vars
- Post-run: collects per-test timing and writes to `timing-file`
- Flaky retries: re-runs failed tests up to N times, quarantines if consistently flaky

**Companion action:** `.github/actions/flaky-test/action.yml`
- Captures rerun counts per test
- Quarantines tests that failed in 2+ consecutive runs
- Produces findings with `severity: warning`

### 2.3 reviewdog PR Annotation Integration

**Action:** `.github/actions/reviewdog/action.yml`

Helper action that pipes linter output into reviewdog for inline PR annotations
while also producing the standard envelope.

**Inputs:**
| Name | Type | Default | Description |
|------|------|---------|-------------|
| `tool-name` | string | — | Linter name for reviewdog |
| `reporter` | string | `github-pr-review` | `github-pr-review` or `github-check` |
| `level` | string | `warning` | `info`, `warning`, or `error` |
| `filter-mode` | string | `diff_context` | `added`, `diff_context`, `file`, `nofilter` |
| `fail-level` | string | `error` | Minimum level to fail CI |

**Two modes:**
1. **Direct:** Action runs reviewdog on a linter command (most common)
2. **Passthrough:** Piped from another action's output — can be composed in a step chain

**Key principle:** reviewdog and the Heretek envelope are complementary.
reviewdog → developer-facing PR comments. Envelope → agent-facing structured data.

### 2.4 Quality Gate Enforcement

**Action:** `.github/actions/quality-gate/action.yml`

Reads `.agent/output.json` from upstream steps and enforces policy thresholds.

**Inputs:**
| Name | Type | Default | Description |
|------|------|---------|-------------|
| `coverage-min` | number | `""` | Enforce minimum coverage % |
| `max-errors` | number | `0` | Maximum allowed error-severity findings |
| `max-warnings` | number | `20` | Maximum allowed warning-severity findings |
| `max-critical-hotspots` | number | `0` | Maximum CodeQL/security critical issues |
| `skip-file` | string | `""` | Path to allowlist for known issues |

**Behavior:**
- Iterates all `.agent/output.json` files in `.agent/results/` (downloaded artifacts)
- For each threshold rule, adds a `checks[]` entry with pass/fail
- Writes merged envelope at the end
- Produces suggestions: `pr:review_request` for coverage misses, `issue:create` for errors
- Degradation detection: compares to `.agent/quality-baseline.json` if it exists

**Baseline management:**
- On success, writes current metrics to `.agent/quality-baseline.json`
- On next run, delta is computed against this baseline
- Prevents quality drift across PRs

---

## Tier 3 — 🟢 Release, Security, and Polish

### 3.1 Semantic Release Automation

**Action:** `.github/actions/semantic-release/action.yml`

Automated version bumping and release creation from conventional commits.

**Inputs:**
| Name | Type | Default | Description |
|------|------|---------|-------------|
| `release-branches` | string | `main,master` | Branches that trigger releases |
| `prerelease-branches` | string | `next,beta,alpha` | Prerelease branches |
| `commit-format` | string | `conventional` | Commit convention |
| `registry` | string | `none` | Package registry: `npm`, `pypi`, `none` |
| `create-release` | bool | `true` | Create GitHub Release |

**Behavior:**
1. Finds the last release tag
2. Parses commits since that tag
3. Determines next version: `fix:` → patch, `feat:` → minor, `BREAKING:` → major
4. Creates GitHub Release with auto-generated changelog
5. Writes envelope with `release` block populated

**Integration:** Feeds into the existing `release` action:
```yaml
- uses: ./.github/actions/semantic-release
  id: version
- uses: ./.github/actions/release
  with:
    version: ${{ steps.version.outputs.next-version }}
```

### 3.2 Dependabot Configuration & Dependency Review

**Files:**
- `.github/dependabot.yml` — Standard config template
- `.github/workflows/dependency-review.yml` — Dependency review with envelope
- `.github/actions/dependabot-envelope/action.yml` — Envelope wrapper

**Dependabot template:**
- npm/pip/cargo/github-actions ecosystem entries with sensible defaults
- Weekly schedule, open-CRs limit, labels preset

**Dependency review workflow:**
- Runs `actions/dependency-review-action` on PRs
- Parses the action's JSON output into findings
- Blocks merge on license violations or critical vulnerabilities
- Writes envelope for agent consumption

### 3.3 Docker CI Hardened Action

**Action:** `.github/actions/docker-ci/action.yml`

Docker build quality gate: lint → vulnerability scan → build → re-scan.

**Inputs:**
| Name | Type | Default | Description |
|------|------|---------|-------------|
| `dockerfile` | string | `./Dockerfile` | Path to Dockerfile |
| `image-name` | string | `""` | Image name for build |
| `scan-severity` | string | `HIGH` | Min severity for Trivy |
| `scan-timeout` | number | `300` | Trivy timeout in seconds |
| `build-args` | string | `{}` | JSON object of build args |
| `platforms` | string | `""` | Comma-separated platforms |

**Steps:**
1. hadolint — standalone Dockerfile linting (not pre-commit gated)
2. Trivy filesystem scan — checks base image vulnerabilities
3. Docker build — optionally multi-platform via buildx
4. Post-build Trivy scan — scans the built image
5. Envelope — merged checks for all four steps

**Relationship to existing release action:**
- `docker-ci` is a **quality gate** that runs on every PR
- `release` is the **publisher** that runs on merge/tag
- A PR must pass `docker-ci` before `release` can publish

### 3.4 AI Slop Checker

**Action:** `.github/actions/ai-slop/action.yml`

Pattern-based detection of AI-generated code artifacts in CI.

**Inputs:**
| Name | Type | Default | Description |
|------|------|---------|-------------|
| `severity` | string | `warning` | Min severity to report |
| `patterns` | string | `[]` | Custom patterns JSON array |
| `include-paths` | string | `["**/*.{js,ts,py,rs,go,java,rb}"]` | Glob patterns |

**Built-in pattern categories:**
1. **Hallucinated imports** — `from nonexistent_module import`, `require('unknown')`
2. **Stale AI artifacts** — "As an AI language model", "This is AI-generated"
3. **Dead comments** — `// Step 1:`, `// The user wants`, verbose step-by-step in comments
4. **Verbose boilerplate** — Overly defensive patterns, redundant error handling
5. **Commit message signals** — AI-hallmarked `git log` messages (also checked by `conventional-pre-commit`)

**Implementation:** Uses `rg` (ripgrep) cached in the action for fast scanning.
Patterns are simple regex checks — no ML inference in the action itself.

---

## Orchestrator: `quality-check.yml`

**Workflow:** `.github/workflows/quality-check.yml`

Composes all quality actions into a single callable workflow, parallelizing
independent checks and aggregating results.

**Design pattern:** Mirrors `check.yml`:

```
quality-check.yml
├── linting job          → lint-ultimate action
├── actionlint job       → actionlint action
├── CodeQL job           → codeql-analysis workflow
├── coverage job         → coverage action
├── quality-gate job     → quality-gate action (reads all upstream artifacts)
```

**All jobs run in parallel** (no cross-dependency), sharing results via artifacts
in `.agent/results/`. The `quality-gate` job depends on all others (`needs:`) and
waits for their artifacts.

**Philosophy:** Every part works standalone. The orchestrator is optional convenience.

---

## Implementation Order

Implement tier-1 items first (one PR per action):
1. `lint-ultimate` action + MegaLinter integration
2. `coverage` action + wiring into `rust-ci`/`js-ci`/`python-ci`
3. `actionlint` action
4. `codeql-analysis.yml` workflow

Then tier-2:
5. `lefthook.yml` config + `lefthook-ci` action
6. `test-matrix` action
7. `reviewdog` action
8. `quality-gate` action
9. `quality-check.yml` orchestrator

Then tier-3:
10. `semantic-release` action
11. `dependabot.yml` + `dependency-review.yml`
12. `docker-ci` action
13. `ai-slop` action

Each item should be its own PR with tests and updated README section.

---

## Rejected / Deferred

- **Self-hosted runner support**: Out of scope for this release. The actions work
  on any runner but don't optimize for self-hosted caching.
- **Cross-repo issue sync**: Pushing findings from one repo's CI to another repo's
  issue tracker. Too specific; defer to custom workflows.
- **Custom ESLint/Ruff rulesets**: Users configure their own lint rules. We only
  provide the runners.
- **Performance benchmarking**: Adding benchmark comparison to CI is a future concern
  for performance-focused users, not general code quality.

---

## Appendix: Pattern Consistency Checklist

All new actions must follow these patterns from the existing codebase:
- [ ] Composite action (not Docker action) unless Docker is required
- [ ] `action.yml` with `name`, `description`, `author: "Heretek-AI"`, `inputs`, `outputs`, `runs`
- [ ] Shell scripts source `agent-envelope.sh` and call `write_envelope()`
- [ ] `outputs` section mirrors `steps.{id}.outputs.{status,summary,agent_action}`
- [ ] Artifact upload step with `if-no-files-found: warn`
- [ ] README section in the main README.md for each new action/workflow
- [ ] Conventional commit messages for all PRs
