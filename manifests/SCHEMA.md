# Manifest Schema

## `manifests/examples.yaml`

Top-level: `examples: []` — array of entries.

Each entry:

| field | type | default | meaning |
|---|---|---|---|
| `repo` | string | required | GitHub repo name under `resonatehq-examples`. |
| `sdk` | `ts` / `py` / `rs` | required | Which Resonate SDK to pin to latest published. |
| `kind` | `worker` / `script` | required | `worker` runs indefinitely; `script` exits on its own. |
| `entry` | string | per-SDK default | Override the run command. Defaults: ts=`npm start`, py=`python main.py`, rs=`cargo run --release`. |
| `timeout_s` | int | `60` (ts/py), `120` (rs) | Maximum wall time. For `worker` kind, this is unused — the worker is killed shortly after the liveness probe completes. |
| `healthy_after_s` | int | `15` (ts/py), `20` (rs) | `worker` only. Seconds to wait before running the liveness probe. |
| `health_regex` | string | `registered\|ready\|listening` | `worker` only. Regex matched against stdout+stderr; must match for the worker to be considered passing. |
| `requires_server` | bool | `false` | If `true`, the runner downloads the latest `resonate` release binary and starts `resonate dev` in the background before running the example. The server is torn down on exit. Examples connect via their hardcoded `http://localhost:8001`; no URL is injected. Use this for examples whose README calls for `resonate dev` / `resonate serve`. |
| `server_kind` | `rust` / `legacy_go` | `rust` | Which Resonate server to spawn. `rust` (default) downloads from `resonatehq/resonate` — single port 8001, current protocol. `legacy_go` downloads from `resonatehq/resonate-legacy-server` — two ports (API on 8001, poll on 8002), older protocol. Use `legacy_go` for examples whose SDK still speaks the older protocol (e.g. Python SDK 0.6.x: long-poll URL is `host:port/{group}/{id}`, not `/poll/{group}/{id}`). Only meaningful when `requires_server: true`. |
| `services` | string[] | `[]` | External services to bring up before `setup:`/`processes:` run. Each name resolves to `runners/lib/services/<name>.sh`, which exports `start_<name>` + `stop_<name>`. Currently supported: `redpanda` (Kafka API at `localhost:9092`, no SASL — needs Docker), `tigerbeetle` (downloads the latest release binary, formats a single-replica data file, starts on port 3000, symlinks the binary into `$EXAMPLE_DIR/bin/tigerbeetle`), `mock_llm` (Python HTTP server on `localhost:8080` that serves canned OpenAI `/v1/chat/completions` and Anthropic `/v1/messages` JSON; exports `OPENAI_BASE_URL`, `ANTHROPIC_BASE_URL`, and dummy API keys so SDK clients route here), and `notify_sink` (tiny Python HTTP server on `localhost:9999` that 200s any GET/POST/PUT; exports `NOTIFY_URL` so webhook-pattern examples can use it as an invoke arg). Start order = list order; stop runs on the runner's EXIT trap so transient failures still clean up. |
| `setup` | string[] | `[]` | Multi-process mode. Sequential pre-steps that must each exit 0 before processes start (e.g., `python schedule.py` to register a cron with the server). Runs after SDK install but after the server is up. |
| `processes` | object[] | `[]` | Multi-process mode. Background processes started in order, each waited for `ready_regex` to appear in stdout/stderr within `healthy_after_s`. Per-entry fields: `name` (label), `entry` (command), `ready_regex` (default `registered\|ready\|listening`; set to empty string `""` to opt out — see below), `healthy_after_s` (default `5`). If a process exits before ready, the run fails with `process_died`. |
| `client` | object | — | Multi-process mode. Final foreground test after all `processes` are healthy. Fields: `entry` (command), `timeout_s` (default `30`). Pass = client exits 0. If `client` is absent and `processes` is non-empty, pass = all-processes-healthy. For blocking-gateway demos see `client.driver` below. |
| `skip` | bool | `false` | Skip this example. Used for Phase 3 examples requiring external services. |

### `client.driver` — blocking-gateway shell driver

For examples whose `/start-workflow`-style endpoint `await`s the entire workflow (so a single `curl` call hangs until a human resolves a latent durable promise), use the `driver` shape instead of `entry`:

```yaml
client:
  driver:
    background:
      entry: "curl -sSf -X POST http://127.0.0.1:5001/start-workflow ..."
    wait_for:
      file: "multi-worker.out"
      pattern: "/resolve/([0-9a-f-]+)"   # first capture group is the value
      capture: promise_id                # exported as $promise_id for `then.entry`
    then:
      entry: "curl -sSf 'http://127.0.0.1:5001/resolve/${promise_id}'"
    timeout_s: 60
```

Flow:

1. **background**: orchestrator spawns `background.entry` in the background — it'll block on the workflow.
2. **wait_for**: orchestrator polls the named file (`multi-<process>.out` or `multi-<process>.err`) every 0.5 s; on a `pattern` match, the first regex capture group is exported as a shell variable named `capture`.
3. **then**: orchestrator runs `then.entry` (with `${capture}` substituted in) — e.g. the unblock URL containing the promise ID.
4. **wait**: orchestrator waits for the background process to exit 0. Its exit signals that the workflow saw the promise resolve and the gateway returned.

`timeout_s` (default `60`) is the overall budget for all four phases. Failure statuses:

- `driver_pattern_timeout` — pattern didn't match within `timeout_s`.
- `driver_then_failed` — `then.entry` exited non-zero.
- `driver_bg_timeout` — background didn't exit after `then.entry` succeeded.
- `driver_bg_failed` — background exited non-zero.

### Adding a new service to `services:`

1. Add `runners/lib/services/<kind>.sh` exporting `start_<kind>()` (return 0 when ready) and `stop_<kind>()` (best-effort cleanup).
2. The dispatcher in `runners/lib/services.sh` discovers it automatically — no other code changes. Add the `ServiceKind` literal to `scripts/build-matrix.ts` so the typecheck stays useful.
3. If the service writes a log under `/tmp/<name>*.log`, add the glob to `.github/workflows/daily.yml`'s `multi-logs-*` upload step so failures are debuggable from the artifact tab.
4. Document the readiness signal in the helper's header — port-open, log-line grep, or service-specific probe.

### `ready_regex: ""` — silent-worker opt-out

Some workers register a function with the Resonate server and then block silently with no startup log line (e.g. the quickstart variants). For these, set `ready_regex: ""` explicitly. The orchestrator skips the regex check and the pass condition for that process becomes: **process is still alive when `healthy_after_s` elapses**. The `process_died` early-exit check is still applied. Pick `healthy_after_s` large enough that the worker has registered with the server before the client phase begins.

## Single-process vs multi-process modes

When `processes` is non-empty (or `setup` is non-empty), the entry runs in **multi-process mode** and the single-process fields (`kind`, `entry`, `timeout_s`, `healthy_after_s`, `health_regex`) are ignored. Examples with a worker + client/invoke split, or a gateway + worker, or a multi-bin Rust crate go here. See `runners/lib/multi.sh` for the orchestrator logic.

## Future: per-repo overrides

Per-repo `.resonate-ci.json` overrides were scoped during Phase 1 design but not implemented — neither `scripts/build-matrix.ts` nor the runners read such a file. If you need an override today, edit the example's row in `manifests/examples.yaml` directly. The per-repo file pattern is a candidate for Phase 1.5 once a non-trivial number of examples need overrides; until then central config is sufficient.
