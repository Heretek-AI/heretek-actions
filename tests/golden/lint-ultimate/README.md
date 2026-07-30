# Golden envelopes for `lint-ultimate`

Goldens for this action are **not committed**. They are generated on first
run via:

```bash
tests/run-action.sh megalinter-passing lint-ultimate
tests/run-action.sh megalinter-failing lint-ultimate
```

This is consistent with `tests/README.md:38-39` — "First-run creates the
golden." The first CI run on a real runner will populate these files; the
diff is reviewed and committed.

## Why no committed goldens for this action

`lint-ultimate` invokes `oxsecurity/megalinter:v7` via Docker. The Docker
run inside `act` is slow and the JSON report is regenerated each time
against the fixture's source files. The only stable, useful contract is
that the parser produces a schema-compatible envelope from any input
report — which the unit test of `build-envelope.sh` (run locally with a
fixture report) verifies; the end-to-end contract is verified by the
golden diff on first CI run.

## Local unit check (no Docker required)

```bash
# Generate a fixture report and run build-envelope.sh against it
cd tests/work
cp ../fixtures/megalinter-failing/* .
# Manually invoke the parser using a sample megalinter-report.json
# (you can fabricate one matching MegaLinter's documented schema)
REPORT_PATH=./megalinter-report.json \
  AGENT_ACTION_PATH=../../.github/actions/lint-ultimate \
  bash ../../.github/actions/lint-ultimate/build-envelope.sh
```