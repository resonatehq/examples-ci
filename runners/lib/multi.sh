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

# shellcheck source=./util.sh
. "$(dirname "${BASH_SOURCE[0]}")/util.sh"

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
      MULTI_STDERR="setup[$i] failed: $(tail_meaningful "multi-setup-$i.err")"
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
          MULTI_STDERR="[$name] died before healthy_after_s: $(tail_meaningful "multi-$name.err")"
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
          MULTI_STDERR="[$name] died before ready: $(tail_meaningful "multi-$name.err")"
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
        MULTI_STDERR="[$name] never matched ready_regex within ${healthy_after_s}s: $(tail_meaningful "multi-$name.err")"
        multi_kill_all
        return 1
      fi
    fi
  done

  # 3. Client phase
  local client_entry client_timeout client_driver_bg
  client_entry=$(printf '%s' "$config"     | jq -r '.client.entry // ""')
  client_driver_bg=$(printf '%s' "$config" | jq -r '.client.driver.background.entry // ""')
  if [ -n "$client_driver_bg" ] && [ "$client_driver_bg" != "null" ]; then
    # Driver shape — for blocking-gateway examples (human-in-the-loop):
    # 1) spawn a background entry that blocks (e.g. POST /start-workflow that
    #    `await`s a workflow waiting on a human promise),
    # 2) tail a process's log file until `pattern` matches; extract the first
    #    capture group and export it as a shell var named `capture`,
    # 3) run the `then` entry with that var substituted in (e.g. the resolve
    #    URL containing the promise ID),
    # 4) wait for the background to exit 0 — its exit signals that the workflow
    #    saw the promise resolve and returned.
    local driver_pattern driver_file driver_capture driver_then driver_timeout
    driver_pattern=$(printf '%s' "$config" | jq -r '.client.driver.wait_for.pattern')
    driver_file=$(printf '%s' "$config"    | jq -r '.client.driver.wait_for.file')
    driver_capture=$(printf '%s' "$config" | jq -r '.client.driver.wait_for.capture // "captured"')
    driver_then=$(printf '%s' "$config"    | jq -r '.client.driver.then.entry')
    driver_timeout=$(printf '%s' "$config" | jq -r '.client.driver.timeout_s // 60')

    echo "multi: driver bg: $client_driver_bg" >&2
    bash -c "$client_driver_bg" > multi-driver-bg.out 2> multi-driver-bg.err &
    local driver_bg_pid=$!
    MULTI_PIDS+=("$driver_bg_pid")
    MULTI_NAMES+=("driver-bg")

    # Phase A: poll the named file for the regex pattern; extract group 1.
    local poll_deadline captured line
    poll_deadline=$(( $(date -u +%s) + driver_timeout ))
    captured=""
    while [ "$(date -u +%s)" -lt "$poll_deadline" ]; do
      if ! kill -0 "$driver_bg_pid" 2>/dev/null; then
        # bg died before producing a match — gateway is broken or
        # workflow short-circuited. Surface as a distinct status.
        MULTI_STATUS="driver_bg_failed"
        MULTI_STDERR="driver-bg: exited before '$driver_pattern' appeared in '$driver_file': $(tail_meaningful multi-driver-bg.err)"
        multi_kill_all
        return 1
      fi
      if [ -f "$driver_file" ]; then
        line=$(grep -E "$driver_pattern" "$driver_file" 2>/dev/null | head -1)
        if [ -n "$line" ] && [[ "$line" =~ $driver_pattern ]]; then
          captured="${BASH_REMATCH[1]}"
          [ -n "$captured" ] && break
        fi
      fi
      sleep 0.5
    done
    if [ -z "$captured" ]; then
      MULTI_STATUS="driver_pattern_timeout"
      MULTI_STDERR="driver: pattern '$driver_pattern' not found in '$driver_file' within ${driver_timeout}s"
      multi_kill_all
      return 1
    fi
    echo "multi: driver captured $driver_capture=$captured" >&2

    # Phase B: run the then-entry with the captured value exported.
    export "$driver_capture=$captured"
    if ! bash -c "$driver_then" > multi-driver-then.out 2> multi-driver-then.err; then
      MULTI_STATUS="driver_then_failed"
      MULTI_STDERR="driver-then: $(tail_meaningful multi-driver-then.err)"
      multi_kill_all
      return 1
    fi

    # Phase C: wait for the background entry to exit within the remaining budget.
    while kill -0 "$driver_bg_pid" 2>/dev/null; do
      if [ "$(date -u +%s)" -ge "$poll_deadline" ]; then
        MULTI_STATUS="driver_bg_timeout"
        MULTI_STDERR="driver-bg: did not exit within ${driver_timeout}s after then-entry succeeded: $(tail_meaningful multi-driver-bg.err)"
        multi_kill_all
        return 1
      fi
      sleep 0.5
    done
    wait "$driver_bg_pid" 2>/dev/null
    local bg_rc=$?
    if [ "$bg_rc" != "0" ]; then
      MULTI_STATUS="driver_bg_failed"
      MULTI_STDERR="driver-bg: exited $bg_rc; $(tail_meaningful multi-driver-bg.err)"
      multi_kill_all
      return 1
    fi

    MULTI_STATUS="passing"
  elif [ -n "$client_entry" ] && [ "$client_entry" != "null" ]; then
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
      MULTI_STDERR="client: $(tail_meaningful multi-client.err)"
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
