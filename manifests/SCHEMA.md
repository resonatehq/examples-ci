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
| `skip` | bool | `false` | Skip this example. Used for Phase 3 examples requiring external services. |

## Future: per-repo overrides

Per-repo `.resonate-ci.json` overrides were scoped during Phase 1 design but not implemented — neither `scripts/build-matrix.ts` nor the runners read such a file. If you need an override today, edit the example's row in `manifests/examples.yaml` directly. The per-repo file pattern is a candidate for Phase 1.5 once a non-trivial number of examples need overrides; until then central config is sufficient.
