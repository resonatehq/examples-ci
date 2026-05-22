#!/usr/bin/env bash
set -uo pipefail

EXAMPLE_DIR="${EXAMPLE_DIR:?required}"
EXAMPLE_NAME="${EXAMPLE_NAME:?required}"
SDK_VERSION="${SDK_VERSION:?required}"
KIND="${KIND:-script}"
ENTRY="${ENTRY:-cargo run --release}"
TIMEOUT_S="${TIMEOUT_S:-120}"
HEALTHY_AFTER_S="${HEALTHY_AFTER_S:-20}"
HEALTH_REGEX="${HEALTH_REGEX:-registered|ready|listening}"
REQUIRES_SERVER="${REQUIRES_SERVER:-false}"
MULTI_CONFIG="${MULTI_CONFIG:-}"

TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN=timeout
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN=gtimeout
fi

WORKSPACE="${GITHUB_WORKSPACE:-$PWD}"
START_TS=$(date -u +%s)
STATUS="install_failed"
STDERR_TAIL=""

emit_result() {
  local end_ts duration
  end_ts=$(date -u +%s)
  duration=$((end_ts - START_TS))
  jq -n \
    --arg repo "$EXAMPLE_NAME" \
    --arg sdk "rs" \
    --arg sdk_version "$SDK_VERSION" \
    --arg status "$STATUS" \
    --argjson duration "$duration" \
    --arg stderr_tail "$STDERR_TAIL" \
    '{repo: $repo, sdk: $sdk, sdk_version: $sdk_version, status: $status, duration_s: $duration, stderr_tail: $stderr_tail}' \
    > "$WORKSPACE/result.json"
}

on_exit() {
  multi_kill_all 2>/dev/null || true
  stop_resonate_server 2>/dev/null || true
  emit_result
}
# shellcheck source=../lib/server.sh
. "$(dirname "$0")/../lib/server.sh"
# shellcheck source=../lib/multi.sh
. "$(dirname "$0")/../lib/multi.sh"
trap on_exit EXIT

cd "$EXAMPLE_DIR"

# Pin Resonate to target version — but only if the example sources from crates.io.
# When Cargo.toml has `resonate = { git = "..." }`, the example is tracking SDK main directly;
# cargo update pulls the latest main commit, which IS "latest" by definition. Skip the pin.
if grep -E '^[[:space:]]*resonate[[:space:]]*=.*git[[:space:]]*=' Cargo.toml >/dev/null 2>&1; then
  echo "resonate dep is git-sourced; pulling latest main via cargo update" >> install.err
  # The actual package id in the lockfile may differ across SDK versions and from
  # the [dependencies] alias. Try the known-good name first, fall back to a broad
  # update, fall back to a no-op (cargo build will use the current lockfile).
  cargo update -p resonate-sdk 2>>install.err \
    || cargo update -p resonate 2>>install.err \
    || cargo update 2>>install.err \
    || true
else
  # Crate is published as `resonate-sdk`; examples typically alias it locally as `resonate`.
  cargo add --rename resonate "resonate-sdk@${SDK_VERSION}" 2>>install.err || true
fi

STATUS="compile_failed"
if ! cargo build --release 2>>build.err; then
  STDERR_TAIL=$(tail -c 4096 build.err 2>/dev/null || true)
  exit 0
fi

if [ "$REQUIRES_SERVER" = "true" ]; then
  STATUS="server_failed"
  if ! start_resonate_server; then
    STDERR_TAIL="resonate server failed to start (see job log)"
    exit 0
  fi
fi

STATUS="runtime_failed"

if [ -n "$MULTI_CONFIG" ]; then
  if run_multi_process "$MULTI_CONFIG"; then
    STATUS="$MULTI_STATUS"
  else
    STATUS="$MULTI_STATUS"
    STDERR_TAIL="$MULTI_STDERR"
  fi
elif [ "$KIND" = "worker" ]; then
  bash -c "$ENTRY" > run.out 2> run.err &
  RUN_PID=$!
  sleep "$HEALTHY_AFTER_S"

  if ! kill -0 "$RUN_PID" 2>/dev/null; then
    STATUS="worker_died"
    STDERR_TAIL=$(tail -c 4096 run.err 2>/dev/null || true)
    exit 0
  fi

  if grep -qE "$HEALTH_REGEX" run.out run.err 2>/dev/null; then
    STATUS="passing"
  else
    STATUS="worker_unhealthy"
  fi

  kill -TERM "$RUN_PID" 2>/dev/null || true
  sleep 1
  kill -KILL "$RUN_PID" 2>/dev/null || true
  STDERR_TAIL=$(tail -c 4096 run.err 2>/dev/null || true)
else
  if [ -z "$TIMEOUT_BIN" ]; then
    STATUS="runner_error"
    STDERR_TAIL="no timeout/gtimeout in PATH (on macOS: brew install coreutils)"
  else
    if "$TIMEOUT_BIN" "$TIMEOUT_S" bash -c "$ENTRY" > run.out 2> run.err; then
      STATUS="passing"
    else
      RC=$?
      if [ "$RC" = "124" ]; then
        STATUS="timeout_unhealthy"
      else
        STATUS="runtime_failed"
      fi
    fi
    STDERR_TAIL=$(tail -c 4096 run.err 2>/dev/null || true)
  fi
fi
