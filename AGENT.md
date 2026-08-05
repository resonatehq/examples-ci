# AGENT — examples-ci

Daily CI matrix that runs every Resonate example against latest published SDKs. See README.md for the user-facing story.

## What lives where

- `manifests/examples.yaml` — single source of truth for enrolled examples. Schema in `manifests/SCHEMA.md`.
- `.github/workflows/daily.yml` — three-stage cron: `resolve` (npm/pip/cargo version detection, baked into matrix), `run` (one shard per example), `aggregate` (collect → summary + gh-pages publish + Echo notify).
- `runners/<sdk>/run.sh` — install-latest-SDK-on-top → run → emit `result.json`. Worker mode uses background spawn + liveness probe (process alive AND stderr matches `health_regex` at `healthy_after_seconds`).
- `runners/lib/util.sh` — `tail_meaningful` helper: last 10 non-empty lines of a file (replaces naive byte-tail; surfaces panic message instead of "run with RUST_BACKTRACE=1" boilerplate). Sourced by every runner + multi.sh.
- `runners/lib/server.sh` — sourced by each per-SDK runner. When `REQUIRES_SERVER=true`, downloads latest `resonate` release binary and spawns `resonate dev` in the background (in-memory mode, port 8001); torn down on exit via the same trap that emits `result.json`. Examples connect via their hardcoded `http://localhost:8001` — no URL injection. `SERVER_KIND=legacy_go` switches to the legacy Go server (resonatehq/resonate-legacy-server) for Py SDK 0.6.x's older long-poll protocol.
- `runners/lib/multi.sh` — sourced by each per-SDK runner. When `MULTI_CONFIG` is a non-empty JSON object (setup / processes / client), orchestrates: sequential `setup` exits → background `processes` started + waited for `ready_regex` → foreground `client` runs with timeout. All processes torn down on exit. Examples with worker+client, gateway+worker, or multi-bin Rust crates go through here. Two opt-ins:
  - **`ready_regex: ""`** on a process — silent worker; pass condition becomes "alive after `healthy_after_s`" (no log-line match).
  - **`client.driver`** — blocking-gateway demos. Spawns `background.entry`, polls a process log for `wait_for.pattern`'s first capture, exports it as `$wait_for.capture`, runs `then.entry`. Pass = background exits 0 within `timeout_s`. New statuses: `driver_pattern_timeout`, `driver_then_failed`, `driver_bg_timeout`, `driver_bg_failed`.
- `runners/lib/services.sh` + `runners/lib/services/<kind>.sh` — sourced by each per-SDK runner. When `SERVICES_JSON` is a non-empty JSON array (e.g. `["redpanda"]`), the dispatcher loads each kind's helper and calls `start_<kind>` in list order; matching `stop_<kind>` calls run on the EXIT trap. Each helper is self-contained: download/start/ready-probe/stop. Currently shipped: `redpanda` (`docker run` the official image; readiness via `rpk cluster info`) and `tigerbeetle` (downloads latest release zip, formats single-replica data file in /tmp, port 3000; symlinks the binary into `$EXAMPLE_DIR/bin/tigerbeetle` so example scripts that reference `./bin/tigerbeetle` work unchanged). Services start AFTER the Resonate server but BEFORE `setup:` — so manifest setup steps and processes can talk to them.
- `scripts/build-matrix.ts` — reads `manifests/examples.yaml`, applies SDK defaults + resolved versions from env, emits matrix JSON for GH Actions.
- `scripts/readme-drift.ts` — separate gate job, shaped like `coverage-check`. Probes every manifest repo for a root `sottovoce.json` (direct `contents` API fetch, concurrency 10 — one `gh` subprocess per repo costs ~100s), shallow-clones the opted-in ones, runs `sottovoce check --diff` in each. Stale fence → job fails → the aggregate gate reddens the run. Deliberately NOT a step in the `run` shard: `result.json` is already uploaded by then, so the badge would say `passing` while the workflow went red. Deliberately not keyed off a manifest field either — the presence of `sottovoce.json` in the example repo IS the enrollment, so adopting a repo needs no PR here. A non-404 probe response is a hard failure rather than "assume not opted in"; a check that silently stops checking is worse than no check.
- `scripts/aggregate.ts` — output contract for two downstream consumers: Echo (`summary.json`) and shields.io (`public/status/<repo>.json`). Schema-versioned (`schema_version: "1"`); bump only on **breaking** changes (renames, removals, semantic shifts) and update Echo's parser in lock-step. Additive optional fields don't bump.

## Downstream consumers

- **Echo Surface 8.** Aggregate step `POST`s `summary.json` to `vars.ECHO_API_URL/api/examples-ci/report` with `secrets.ECHO_API_KEY`. Echo persists, diffs against yesterday, briefs NEW/ONGOING/RESOLVED failures to Discord `#echo-ai-assistant`.
- **shields.io.** `public/status/<repo>.json` lives on gh-pages branch. Example READMEs reference `https://img.shields.io/endpoint?url=https://resonatehq.github.io/examples-ci/status/<repo>.json`.

## Common ops

- **Run one example locally**: see README.md "Running locally."
- **Trigger a manual full run**: `gh workflow run daily.yml --repo resonatehq/examples-ci`
- **Trigger a subset**: `gh workflow run daily.yml --repo resonatehq/examples-ci -f examples=foo,bar`. The aggregator's gh-pages publish + Echo notify are SKIPPED on subset runs so the dashboard isn't overwritten; use no-arg to refresh.
- **Add an example**: edit `manifests/examples.yaml`, open PR.
- **Debug a failure**: download the `multi-logs-<repo>` artifact for the failing run — includes every process's stdout/stderr plus `/tmp/resonate.log`. `stderr_tail` in `result.json` is line-based (last 10 non-empty lines via `tail_meaningful`) so panic messages survive even with verbose backtraces.

## Phasing

- **Phase 1** (live): single-process examples, no Resonate server required.
- **Phase 1.5** (live, 54 enrolled): server-required + multi-process examples. `requires_server: true` spawns `resonate dev`; `setup` / `processes` / `client` schema fields orchestrate multi-step demos (worker + client/invoke, gateway + worker, multi-bin Rust). Covers load-balancing, recursive-factorial, schedule-py, async-http-api, durable-sleep, async-rpc, quickstart variants, fan-out-fan-in, human-in-the-loop-py.
  - Wave 10 (2026-05-23) extended schema with `services:` — first external-process examples: kafka-worker-ts/rs against Redpanda + tigerbeetle-account-creation-ts. See "Adding a new service" in `manifests/SCHEMA.md`.
  - 4 manifest entries are `skip: true` pending upstream debugs (HITL × 2, schedule-rs, kafka-worker-py). See their inline comments for the open thread.
- **Phase 2** (not started): AI agent examples with mocked LLM calls (~7 examples). Shape not yet decided.
- **Phase 3** (in progress): Kafka via `services:` (Redpanda) + TigerBeetle landed wave-10 above. Still gated: cloud-creds examples (aws-lambda, lambda-workers-py, databricks-in-the-loop, supabase-edge); the recommendation is `skip: true` until someone files a real-world bug their CI would have caught.

## Don't

- Don't pin SDK versions per-shard. `resolve` does it once; every shard uses the same trio. Otherwise mid-run SDK releases produce split results.
- Don't increase the daily cron frequency. Examples don't change minute-to-minute and we'd burn the free GH Actions tier.
- Don't add unit-test calls. This is integration — running examples — not unit testing the SDK.
- Don't fold the README drift check into the `run` shard or the badge. The badge answers "does this example run"; drift answers "does its README show the code that runs". Merging them makes both unreadable.
- Don't run the workflow in PRs (gh-pages publish + Echo notify are gated by `github.ref == 'refs/heads/main'`).

## Decisions baked in (2026-05-19)

1. Repo is public — needed for free GH Actions minutes + Pages.
2. Manifest is convention-first (defaults per SDK); `.resonate-ci.json` in the example repo overrides if needed. No 96-repo PR sweep required to land Phase 1.
3. Phase 2 LLM examples run mocked (CI tests SDK compat, not LLM quality).
4. Failures auto-file a tracker issue in `resonatehq/examples-ci/issues`, auto-close on RESOLVED-TODAY (handled by Echo workflow, not this repo).
5. Flaky color = `orange`. Yellow is overloaded with "info" elsewhere in shields.io.
