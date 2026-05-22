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
| `requires_server` | bool | `false` | If `true`, the runner downloads the latest `resonate` release binary and starts `resonate dev` (in-memory, port 8001) in the background before running the example. The server is torn down on exit. Examples connect via their hardcoded `http://localhost:8001`; no URL is injected. Use this for examples whose README calls for `resonate dev` / `resonate serve`. |
| `setup` | string[] | `[]` | Multi-process mode. Sequential pre-steps that must each exit 0 before processes start (e.g., `python schedule.py` to register a cron with the server). Runs after SDK install but after the server is up. |
| `processes` | object[] | `[]` | Multi-process mode. Background processes started in order, each waited for `ready_regex` to appear in stdout/stderr within `healthy_after_s`. Per-entry fields: `name` (label), `entry` (command), `ready_regex` (default `registered\|ready\|listening`), `healthy_after_s` (default `5`). If a process exits before ready, the run fails with `process_died`. |
| `client` | object | — | Multi-process mode. Final foreground test after all `processes` are healthy. Fields: `entry` (command), `timeout_s` (default `30`). Pass = client exits 0. If `client` is absent and `processes` is non-empty, pass = all-processes-healthy. |
| `skip` | bool | `false` | Skip this example. Used for Phase 3 examples requiring external services. |

## Single-process vs multi-process modes

When `processes` is non-empty (or `setup` is non-empty), the entry runs in **multi-process mode** and the single-process fields (`kind`, `entry`, `timeout_s`, `healthy_after_s`, `health_regex`) are ignored. Examples with a worker + client/invoke split, or a gateway + worker, or a multi-bin Rust crate go here. See `runners/lib/multi.sh` for the orchestrator logic.

## Future: per-repo overrides

Per-repo `.resonate-ci.json` overrides were scoped during Phase 1 design but not implemented — neither `scripts/build-matrix.ts` nor the runners read such a file. If you need an override today, edit the example's row in `manifests/examples.yaml` directly. The per-repo file pattern is a candidate for Phase 1.5 once a non-trivial number of examples need overrides; until then central config is sufficient.
