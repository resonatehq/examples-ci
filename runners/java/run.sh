#!/usr/bin/env bash
set -uo pipefail

EXAMPLE_DIR="${EXAMPLE_DIR:?required}"
EXAMPLE_NAME="${EXAMPLE_NAME:?required}"
# Report-only for java: the examples pin the SDK in their committed
# build.gradle.kts, so an empty resolved version must not fail the row.
SDK_VERSION="${SDK_VERSION:-}"
BUILD_ONLY="${BUILD_ONLY:-false}"
KIND="${KIND:-script}"
ENTRY="${ENTRY:-}"
TIMEOUT_S="${TIMEOUT_S:-180}"
HEALTHY_AFTER_S="${HEALTHY_AFTER_S:-15}"
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
    --arg sdk "java" \
    --arg sdk_version "$SDK_VERSION" \
    --arg status "$STATUS" \
    --argjson duration "$duration" \
    --arg stderr_tail "$STDERR_TAIL" \
    --arg server_version "${RESONATE_SERVER_TAG:-}" \
    --arg server_kind "${RESONATE_SERVER_KIND:-}" \
    '{repo: $repo, sdk: $sdk, sdk_version: $sdk_version, status: $status, duration_s: $duration, stderr_tail: $stderr_tail, server_version: $server_version, server_kind: $server_kind}' \
    > "$WORKSPACE/result.json"
}

on_exit() {
  multi_kill_all 2>/dev/null || true
  stop_services 2>/dev/null || true
  stop_resonate_server 2>/dev/null || true
  emit_result
}
# shellcheck source=../lib/util.sh
. "$(dirname "$0")/../lib/util.sh"
# shellcheck source=../lib/server.sh
. "$(dirname "$0")/../lib/server.sh"
# shellcheck source=../lib/services.sh
. "$(dirname "$0")/../lib/services.sh"
# shellcheck source=../lib/multi.sh
. "$(dirname "$0")/../lib/multi.sh"
trap on_exit EXIT

cd "$EXAMPLE_DIR"

# Gradle resolves and compiles in one step; no separate install phase.
# Use --no-daemon so the process exits cleanly and --stacktrace for useful
# failure output. The Gradle wrapper is committed in each example repo.
# Runtime entries (`./gradlew run` etc.) reuse this build's outputs, so the
# gradle invocations below start fast.
STATUS="compile_failed"
if ! ./gradlew build --no-daemon --stacktrace 2>>build.err; then
  STDERR_TAIL=$(tail_meaningful build.err)
  exit 0
fi

# build_only: compile is the full check; no server, no runtime.
if [ "$BUILD_ONLY" = "true" ]; then
  STATUS="passing"
  exit 0
fi

if [ "$REQUIRES_SERVER" = "true" ]; then
  STATUS="server_failed"
  if ! start_resonate_server; then
    STDERR_TAIL="resonate server failed to start (see job log)"
    exit 0
  fi
fi

if [ -n "${SERVICES_JSON:-}" ] && [ "$SERVICES_JSON" != "[]" ]; then
  STATUS="services_failed"
  if ! start_services; then
    STDERR_TAIL="services failed to start (see job log)"
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
  if [ -z "$ENTRY" ]; then
    STATUS="runner_error"
    STDERR_TAIL="java worker mode requires an entry command (entry:)"
    exit 0
  fi
  bash -c "$ENTRY" > run.out 2> run.err &
  RUN_PID=$!
  sleep "$HEALTHY_AFTER_S"

  if ! kill -0 "$RUN_PID" 2>/dev/null; then
    STATUS="worker_died"
    STDERR_TAIL=$(tail_meaningful run.err)
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
  STDERR_TAIL=$(tail_meaningful run.err)
else
  if [ -z "$ENTRY" ]; then
    STATUS="runner_error"
    STDERR_TAIL="java runtime mode requires an entry command (entry:)"
    exit 0
  fi
  if [ -z "$TIMEOUT_BIN" ]; then
    STATUS="runner_error"
    STDERR_TAIL="no timeout/gtimeout in PATH"
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
    STDERR_TAIL=$(tail_meaningful run.err)
  fi
fi
