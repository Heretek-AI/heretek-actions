# OCR Workflow Optimization

**Date:** 2026-07-30
**Status:** Approved design (awaiting implementation)

## Background

The `ocr-review.yml` and `ocr-scan.yml` workflows provide AI-powered code review via
[Open Code Review (OCR)](https://open-codereview.ai). Consumers reference these reusable
workflows from `Heretek-AI/heretek-actions` to add LLM-backed review to their repos.

### Problems addressed

1. **ocr-review.yml uses the marketplace composite action** (`alibaba/open-code-review@main`),
   a black box that doesn't expose `--background`, `--concurrency`, or other CLI flags the
   official CI/CD docs recommend for production quality.
2. **ocr-scan.yml uses legacy `llm.*` config keys** — works in v1.8.1 but deprecated in favor
   of the provider-based config model (`custom_providers.*`).
3. **No credential validation** before the expensive scan — wastes 30-min timeout if creds
   are wrong.
4. **No version pinning** — `@alibaba-group/open-code-review` floats to latest, risking
   breaking changes.
5. **Default model fallback is wrong** — defaults to `claude-sonnet-4-20250514` instead of
   `deepseek-v4-flash`.
6. **No concurrency control** — defaults to 8 parallel sub-agents, risks Deepseek rate limits.
7. **No `--background` context** — the single highest-leverage flag for review quality
   (passes PR title to LLM for file-context understanding).
8. **No `--no-plan` toggle** — the scan pre-pass adds ~1 LLM call per file; users should
   opt out for cost efficiency.

## Approach: Direct CLI for both workflows

Replace the marketplace action (`alibaba/open-code-review@main`) with direct `ocr review` /
`ocr scan` CLI invocations. This gives consumers full control over flags via workflow inputs,
matching the official CI/CD customization patterns.

### Config model

Use the **custom provider** config (not legacy `llm.*`):

```bash
ocr config set provider heretek-deepseek
ocr config set custom_providers.heretek-deepseek.url "${OCR_LLM_URL}"
ocr config set custom_providers.heretek-deepseek.protocol "${OCR_PROTOCOL}"
ocr config set custom_providers.heretek-deepseek.model "${OCR_LLM_MODEL}"
ocr config set custom_providers.heretek-deepseek.api_key "${OCR_LLM_TOKEN}"
ocr config set llm.extra_body '{"thinking": {"type": "disabled"}}'
```

Provider name `heretek-deepseek` is internal only — consumers never reference it. All values
come from their GitHub secrets / inputs / vars.

## ocr-review.yml Design

### Triggers

- `pull_request_target` (opened, synchronize, reopened) — for fork-safe secret access
- `issue_comment` with body starting `/open-code-review` or `@open-code-review`
- `workflow_call` — for consumer workflows

### Inputs

| Input | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `ocr-llm-model` | string | no | `""` | LLM model override |
| `ocr-use-anthropic` | string | no | `"true"` | Anthropic vs OpenAI protocol |
| `ocr-concurrency` | string | no | `"5"` | Parallel sub-agents |
| `ocr-llm-auth-header` | string | no | `""` | Custom auth header name |

### Secrets

| Secret | Required | Description |
|--------|----------|-------------|
| `ocr_llm_url` | yes | LLM API endpoint URL |
| `ocr_llm_token` | yes | Auth token |
| `repo_token` | no | GitHub token (defaults to GITHUB_TOKEN) |
| `ocr_llm_model` | no | Default model (overridable by input) |

### Steps

1. **Checkout** — `actions/checkout@v4` with `fetch-depth: 0`
2. **Install OCR** — `npm install -g @alibaba-group/open-code-review@1.8.1`
3. **Configure LLM** — custom provider setup from secrets/inputs/vars chain
4. **Validate LLM** — `ocr llm test` (fail-fast if creds wrong)
5. **Run OCR Review** — with `--background "$PR_TITLE"`, `--concurrency` from input
6. **Build Agent Envelope** — existing `ocr-envelope` action
7. **Upload artifacts** — existing pattern

### Model resolution chain

```
secrets.ocr_llm_model → inputs.ocr-llm-model → vars.OCR_LLM_MODEL → "deepseek-v4-flash"
```

### Protocol resolution chain

```
inputs.ocr-use-anthropic → vars.OCR_LLM_USE_ANTHROPIC → "true"
```

Mapping: if resolved value is `"true"`, protocol is `"anthropic"`; otherwise `"openai"`.
This determines the `custom_providers.heretek-deepseek.protocol` value in the config step.

### Concurrency group

Keep the existing group logic that prevents duplicate runs and handles issue_comment events.

## ocr-scan.yml Design

### Triggers

- `workflow_dispatch` — manual trigger
- `workflow_call` — consumer workflows

### Inputs

| Input | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `scan-path` | string | no | `"."` | Path to scan |
| `ocr-llm-model` | string | no | `""` | LLM model override |
| `ocr-use-anthropic` | string | no | `"true"` | Anthropic vs OpenAI protocol |
| `ocr-concurrency` | string | no | `"5"` | Parallel sub-agents |
| `ocr-no-plan` | string | no | `"true"` | Skip PLAN_TASK pre-pass (`"false"` for max quality) |
| `ocr-llm-auth-header` | string | no | `""` | Custom auth header name |

### Secrets

Same as review workflow.

### Steps

Same install → configure → validate → run → envelope → upload pattern.

### `--no-plan` flag

The `ocr scan` subcommand has a `--no-plan` flag that skips the per-file PLAN_TASK
pre-pass (saves ~1 LLM call per file). Default is `true` (opt-out) for cost efficiency.
Set `ocr-no-plan: "false"` for maximum review quality at higher token cost.

## User-Facing Changes

### For consumers upgrading from current workflows

**No breaking changes.** All existing inputs still work. The LLM configuration uses the
same secrets (`OCR_LLM_URL`, `OCR_LLM_TOKEN`, etc.). New inputs are additive:

- `ocr-concurrency` (both) — tune parallel agents
- `ocr-no-plan` (scan only) — skip/keep the plan pre-pass

### Per-review token cost

Estimate with Deepseek v4-flash and default concurrency 5:

- **ocr-review** (diff on a PR): ~15-60K tokens per review, depending on PR size
- **ocr-scan** (full codebase): ~20-100K tokens per file scan, can be expensive on
  large repos. `--no-plan` saves ~5-10K tokens per file.

## Verification Plan

1. Trigger `ocr-scan` via workflow_dispatch on this repo — verify findings are non-empty
   and envelope parses correctly
2. Create a test PR and verify `ocr-review` posts inline comments
3. Verify `ocr llm test` correctly fails when creds are wrong (no wasted scan time)
4. Test `ocr-no-plan: "false"` produces better quality on a known file
5. Verify artifact upload includes both `.agent/output.json` and `.ocr/`

## Open Questions

- Should we add a `ocr-pin-version` input so consumers can pin a specific OCR version
  without editing the workflow file? (Deferred — can add later)
- Should scan findings auto-create issues? Currently disabled (`if: false`). Could expose
  as input `ocr-create-issues`. (Out of scope for this round.)
