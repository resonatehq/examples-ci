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

## Per-example `.resonate-ci.json` (optional override)

An example repo may carry a `.resonate-ci.json` at its root with the same shape as a manifest entry (minus `repo`):

```json
{
  "kind": "worker",
  "entry": "bun run dev",
  "healthy_after_s": 20,
  "health_regex": "stripe.webhook.ready"
}
```

The matrix runner prefers per-repo `.resonate-ci.json` over the central manifest entry. Use it when an example's defaults are insufficient — typically workers with non-standard ready-line patterns.

**Phase 1 policy**: don't open the 96-repo PR sweep for `.resonate-ci.json` files. Add them only when a specific example needs the override.
