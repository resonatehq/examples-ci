# examples-ci

Daily compatibility check for [resonatehq-examples](https://github.com/resonatehq-examples). Every example is run against the latest published Resonate SDK; results land as a JSON summary (consumed by Echo) and per-example shields.io endpoints (consumed by example READMEs).

## What it does

1. **07:00 UTC daily.** Resolve latest published versions of `@resonatehq/sdk` (npm), `resonate-sdk` (PyPI), `resonate` (crates.io). Pin once; every matrix shard uses the same resolved trio so "the X.Y.Z release broke N examples" is provable.
2. **Matrix run.** One job per example in [manifests/examples.yaml](manifests/examples.yaml). Each shard clones the example, installs the latest SDK on top of the example's pinned deps, runs the entry command, captures status + stderr tail.
3. **Aggregate.** Per-shard `result.json` artifacts merge into:
   - `summary.json` — array of per-example results, posted to Echo at `POST /api/examples-ci/report`.
   - `public/status/<repo>.json` — shields.io endpoint payloads, published to `gh-pages` for README badges.
   - `public/index.html` — dashboard at [resonatehq.github.io/examples-ci](https://resonatehq.github.io/examples-ci/).
4. **README snippet drift.** For every manifest repo that has opted in, checks that the code fences in its README still match the source files they quote. See below.

## README snippet drift

The matrix proves an example *runs*. It says nothing about the README — which is what most readers actually copy from. A repo can carry a green badge while its README calls a method that doesn't exist, and nothing notices.

The `readme-drift` job closes that gap for repos that opt in. Opting in means committing a `sottovoce.json` and a one-line directive comment above each fence, so the fence is generated from the repo's own source instead of hand-copied ([sottovoce](https://github.com/flossypurse-studios/sottovoce)):

```json
{ "docs": ["README.md"], "sources": { "self": { "path": "." } } }
```

```markdown
<!-- sotto self:worker.ts#worker -->
```

The job clones each opted-in repo and runs `sottovoce check --diff`; a stale fence fails the daily run the same way a failing example does, and the log shows exactly which lines diverged. Repos without a `sottovoce.json` are skipped, so adoption is per-repo and nothing in this repo needs updating when one joins. Skipped (`skip: true`) examples are still checked — whether an example runs in CI and whether its README is honest are independent questions.

Fixing drift is `npx sottovoce sync` in the example repo (or correcting the source, if the README was the one telling the truth).

## Status taxonomy

| Status | Meaning |
|---|---|
| `passing` | One-shot example exited 0, or worker passed liveness probe within `healthy_after_seconds`. |
| `install_failed` | Package install (npm/pip/cargo) errored before the example ran. |
| `compile_failed` | Rust only: `cargo build` failed. |
| `server_failed` | `requires_server: true` example — Resonate server binary download or startup failed. |
| `runtime_failed` | Non-zero exit during run. |
| `worker_died` | Worker process exited before liveness probe. |
| `worker_unhealthy` | Worker stayed alive but didn't match `health_regex`. |
| `timeout_unhealthy` | One-shot example hit timeout without exiting. |
| `setup_failed` | Multi-process example — a `setup:` command exited non-zero. |
| `process_died` | Multi-process example — a `processes:` entry exited before its `ready_regex` matched. |
| `process_unhealthy` | Multi-process example — a `processes:` entry stayed alive but didn't match `ready_regex` within `healthy_after_s`. |
| `client_failed` | Multi-process example — `client.entry` exited non-zero. |
| `client_timeout` | Multi-process example — `client.entry` hit `client.timeout_s`. |
| `driver_pattern_timeout` | `client.driver` shape — `wait_for.pattern` never matched in the named file within `timeout_s`. |
| `driver_then_failed` | `client.driver` shape — `then.entry` exited non-zero. |
| `driver_bg_timeout` | `client.driver` shape — background process didn't exit after `then.entry` succeeded. |
| `driver_bg_failed` | `client.driver` shape — background process exited non-zero. |

## Layout

```
.github/workflows/daily.yml  cron orchestrator (resolve → run → aggregate)
runners/{ts,py,rs,go}/run.sh per-SDK install + run + capture
scripts/build-matrix.ts      manifests/examples.yaml → GH Actions matrix JSON
scripts/aggregate.ts         per-shard result.json → summary + status/*.json + dashboard
scripts/readme-drift.ts      opted-in repos → README fences vs. their source files
manifests/examples.yaml      source of truth: which examples to run
manifests/SCHEMA.md          field semantics + .resonate-ci.json override
```

## Adding an example

Add a row to [manifests/examples.yaml](manifests/examples.yaml). Override per-example via the manifest fields (`entry`, `kind`, `timeout_s`, `healthy_after_s`, `health_regex`) — see [manifests/SCHEMA.md](manifests/SCHEMA.md). Per-repo `.resonate-ci.json` overrides were scoped for Phase 1.5 but are not yet read by the runner.

## Running locally

```bash
EXAMPLE_DIR=../example-async-rpc-ts \
EXAMPLE_NAME=example-async-rpc-ts \
SDK_VERSION=0.10.4 \
KIND=worker \
ENTRY="bun run start" \
runners/ts/run.sh
cat result.json
```

## Manual full run

```bash
gh workflow run daily.yml --repo resonatehq/examples-ci
# subset:
gh workflow run daily.yml --repo resonatehq/examples-ci -f examples=example-async-rpc-ts,example-money-transfer-py
```
