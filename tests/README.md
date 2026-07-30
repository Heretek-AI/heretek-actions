# Test Harness

Composite actions in `.github/actions/` are notoriously hard to test in
isolation. This harness uses [`act`](https://github.com/nektos/act) to run
each action against a fixture repo and diff the produced `.agent/output.json`
against a golden snapshot.

## Layout

```
tests/
├── run-action.sh             # Runner — invokes act on a fixture
├── run-all.sh                # Run all action/fixture pairs in parallel
├── fixtures/                 # Tiny repos with intentional state
│   ├── rust-passing/         # cargo test passes
│   ├── rust-failing/         # cargo test fails on purpose
│   ├── js-passing/           # eslint + vitest green
│   ├── js-failing/           # vitest fails
│   ├── python-passing/       # ruff + pytest green
│   ├── python-failing/       # pytest fails
│   ├── docker-passing/       # clean Dockerfile
│   └── docker-failing/       # bad Dockerfile (hadolint warnings)
├── golden/                   # Expected envelopes, keyed by action/fixture
│   ├── rust-ci/
│   │   ├── rust-passing.json
│   │   └── rust-failing.json
│   └── ...
└── work/                     # Sandboxes — gitignored, transient
```

## Usage

```bash
# Run a single action against a fixture
tests/run-action.sh rust-passing rust-ci

# First run with no golden: writes the snapshot
tests/run-action.sh rust-failing rust-ci    # creates golden/rust-ci/rust-failing.json

# Subsequent runs diff against golden — non-zero exit on mismatch
tests/run-action.sh rust-passing rust-ci
```

## CI Integration

`tests/run-all.sh` iterates over all action/fixture pairs and reports a summary:

```bash
tests/run-all.sh                # parallel (default jobs = nproc)
tests/run-all.sh --serial       # sequential
tests/run-all.sh --dry-run      # print matrix, don't execute
tests/run-all.sh --only rust-ci # run only matching actions
tests/run-all.sh --jobs 4       # cap parallel workers
```

Wire it into a `ci` workflow:

```yaml
name: Action Tests
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: |
          curl -fsSL https://raw.githubusercontent.com/nektos/act/master/install.sh | sudo bash
      - run: tests/run-all.sh
```

## Conventions

1. **One fixture per scenario**, not per language. `rust-failing` is the
   same fixture reused for `rust-ci` failing-case and (later) for
   `coverage` failing-coverage-case.
2. **Goldens strip volatile fields** — `created_at`, `duration_ms`, `repository.sha`,
   `repository.run_id`. Don't add those to golden files.
3. **First-run creates the golden.** On any schema change, delete goldens to
   regenerate. Review the diff carefully before committing.
4. **Fixtures stay tiny.** A passing rust fixture is ~10 lines of Cargo.toml +
   one test file. If a fixture grows past 50 lines, split it.

## Known Limitations

- `act` does not perfectly emulate GitHub-hosted runners — network, secrets,
  and some `GITHUB_*` env vars behave differently. Envelope schema validation
  is the main check; behavioral testing requires real runners.
- Docker-in-Docker (`docker build` inside `act`) is slow. For `docker-ci`,
  prefer `docker buildx build --load=false` or skip image builds in tests.
- No full JSON-schema validator — the harness only checks that
  `agent_action` is in the schema enum. Add `ajv` / `jsonschema` if you
  need exhaustive validation.
