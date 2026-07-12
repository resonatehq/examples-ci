#!/usr/bin/env bash
set -uo pipefail

EXAMPLE_DIR="${EXAMPLE_DIR:?required}"
EXAMPLE_NAME="${EXAMPLE_NAME:?required}"
SDK_VERSION="${SDK_VERSION:?required}"
BUILD_ONLY="${BUILD_ONLY:-false}"
KIND="${KIND:-script}"
ENTRY="${ENTRY:-}"
TIMEOUT_S="${TIMEOUT_S:-180}"

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
  emit_result
}
# shellcheck source=../lib/util.sh
. "$(dirname "$0")/../lib/util.sh"
trap on_exit EXIT

cd "$EXAMPLE_DIR"

# Gradle resolves and compiles in one step; no separate install phase.
# Use --no-daemon so the process exits cleanly and --stacktrace for useful
# failure output. The Gradle wrapper is committed in each example repo.
STATUS="compile_failed"
if ! ./gradlew build --no-daemon --stacktrace 2>>build.err; then
  STDERR_TAIL=$(tail_meaningful build.err)
  exit 0
fi

if [ "$BUILD_ONLY" = "true" ]; then
  STATUS="passing"
  exit 0
fi

# Runtime mode (not yet used; all current java rows are build_only).
if [ -z "$ENTRY" ]; then
  STATUS="runner_error"
  STDERR_TAIL="java runtime mode requires an entry command (entry:)"
  exit 0
fi

STATUS="runtime_failed"
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
