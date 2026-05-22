#!/usr/bin/env bash
# Sourced by per-SDK runners when MULTI_CONFIG is set (JSON object).
# Schema (matches manifests/SCHEMA.md):
#   {
#     "setup":      ["cmd", ...],                                       # optional sequential exit-0 steps
#     "processes":  [{"name","entry","ready_regex","healthy_after_s"}], # optional background N
#     "client":     {"entry","timeout_s"}                               # optional foreground test
#   }
#
# Outputs (via global env vars; caller reads + emits result.json):
#   MULTI_STATUS  — one of: passing, setup_failed, process_died,
#                   process_unhealthy, client_failed, client_timeout
#   MULTI_STDERR  — stderr tail of the failing step (if any)
#
# Requires: jq, $TIMEOUT_BIN already detected by caller.

MULTI_PIDS=()
MULTI_NAMES=()

multi_kill_all() {
  local pid
  for pid in "${MULTI_PIDS[@]}"; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  sleep 1
  for pid in "${MULTI_PIDS[@]}"; do
    kill -KILL "$pid" 2>/dev/null || true
  done
  MULTI_PIDS=()
}

run_multi_process() {
  local config="$1"
  local i n cmd

  # 1. Setup phase
  n=$(printf '%s' "$config" | jq '.setup // [] | length')
  for ((i=0; i<n; i++)); do
    cmd=$(printf '%s' "$config" | jq -r ".setup[$i]")
    echo "multi: setup[$i] $cmd" >&2
    if ! bash -c "$cmd" > "multi-setup-$i.out" 2> "multi-setup-$i.err"; then
      MULTI_STATUS="setup_failed"
      MULTI_STDERR="setup[$i] failed: $(tail -c 4096 multi-setup-$i.err 2>/dev/null || true)"
      return 1
    fi
  done

  # 2. Processes phase
  n=$(printf '%s' "$config" | jq '.processes // [] | length')
  local name entry ready_regex healthy_after_s deadline
  for ((i=0; i<n; i++)); do
    name=$(printf '%s' "$config"     | jq -r ".processes[$i].name // \"proc-$i\"")
    entry=$(printf '%s' "$config"    | jq -r ".processes[$i].entry")
    # Use raw extraction so an explicit "" stays empty (opt-out signal).
    # // only fires on absent/null, so a missing field still gets the default.
    ready_regex=$(printf '%s' "$config" | jq -r ".processes[$i].ready_regex // \"registered|ready|listening\"")
    healthy_after_s=$(printf '%s' "$config" | jq -r ".processes[$i].healthy_after_s // 5")

    echo "multi: starting [$name] $entry (ready_regex=$ready_regex, healthy_after_s=$healthy_after_s)" >&2
    bash -c "$entry" > "multi-$name.out" 2> "multi-$name.err" &
    local pid=$!
    MULTI_PIDS+=("$pid")
    MULTI_NAMES+=("$name")

    deadline=$(( $(date -u +%s) + healthy_after_s ))
    if [ -z "$ready_regex" ]; then
      # Opt-out: silent worker. Pass = still alive after healthy_after_s.
      while [ "$(date -u +%s)" -lt "$deadline" ]; do
        if ! kill -0 "$pid" 2>/dev/null; then
          MULTI_STATUS="process_died"
          MULTI_STDERR="[$name] died before healthy_after_s: $(tail -c 4096 multi-$name.err 2>/dev/null || true)"
          multi_kill_all
          return 1
        fi
        sleep 0.5
      done
      echo "multi: [$name] alive after ${healthy_after_s}s (no ready_regex)" >&2
    else
      while [ "$(date -u +%s)" -lt "$deadline" ]; do
        if ! kill -0 "$pid" 2>/dev/null; then
          MULTI_STATUS="process_died"
          MULTI_STDERR="[$name] died before ready: $(tail -c 4096 multi-$name.err 2>/dev/null || true)"
          multi_kill_all
          return 1
        fi
        if grep -qE "$ready_regex" "multi-$name.out" "multi-$name.err" 2>/dev/null; then
          echo "multi: [$name] ready" >&2
          break
        fi
        sleep 0.5
      done
      if ! grep -qE "$ready_regex" "multi-$name.out" "multi-$name.err" 2>/dev/null; then
        MULTI_STATUS="process_unhealthy"
        MULTI_STDERR="[$name] never matched ready_regex within ${healthy_after_s}s: $(tail -c 4096 multi-$name.err 2>/dev/null || true)"
        multi_kill_all
        return 1
      fi
    fi
  done

  # 3. Client phase
  local client_entry client_timeout
  client_entry=$(printf '%s' "$config" | jq -r '.client.entry // ""')
  if [ -n "$client_entry" ] && [ "$client_entry" != "null" ]; then
    client_timeout=$(printf '%s' "$config" | jq -r '.client.timeout_s // 30')
    echo "multi: client $client_entry (timeout=${client_timeout}s)" >&2
    if "$TIMEOUT_BIN" "$client_timeout" bash -c "$client_entry" > multi-client.out 2> multi-client.err; then
      MULTI_STATUS="passing"
    else
      local rc=$?
      if [ "$rc" = "124" ]; then
        MULTI_STATUS="client_timeout"
      else
        MULTI_STATUS="client_failed"
      fi
      MULTI_STDERR="client: $(tail -c 4096 multi-client.err 2>/dev/null || true)"
      multi_kill_all
      return 1
    fi
  else
    # No client — all-processes-healthy is the pass criterion
    MULTI_STATUS="passing"
  fi

  multi_kill_all
  return 0
}
