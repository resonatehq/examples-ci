#!/usr/bin/env bash
set -uo pipefail

EXAMPLE_DIR="${EXAMPLE_DIR:?required}"
EXAMPLE_NAME="${EXAMPLE_NAME:?required}"
SDK_VERSION="${SDK_VERSION:?required}"
KIND="${KIND:-script}"
ENTRY="${ENTRY:-npm start}"
TIMEOUT_S="${TIMEOUT_S:-60}"
HEALTHY_AFTER_S="${HEALTHY_AFTER_S:-15}"
HEALTH_REGEX="${HEALTH_REGEX:-registered|ready|listening}"
REQUIRES_SERVER="${REQUIRES_SERVER:-false}"
MULTI_CONFIG="${MULTI_CONFIG:-}"
BUILD_ONLY="${BUILD_ONLY:-false}"
SUBDIRS_JSON="${SUBDIRS_JSON:-}"

# Detect timeout binary (GNU `timeout` on Linux CI, `gtimeout` from coreutils on macOS).
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
    --arg sdk "ts" \
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

# build_only: install from lockfile, compile/typecheck, done.
# No SDK version pin, no server, no runtime.
if [ "$BUILD_ONLY" = "true" ]; then
  STATUS="compile_failed"

  # Install + build one package directory (path relative to EXAMPLE_DIR).
  # Runs in a subshell so cwd changes are scoped.
  build_one_ts_dir() {
    local dir="$1"
    (
      cd "$dir" 2>>"$EXAMPLE_DIR/build.err" || exit 1

      if [ -f bun.lockb ] || [ -f bun.lock ]; then
        bun install 2>>"$EXAMPLE_DIR/build.err" || exit 1
      elif [ -f package-lock.json ]; then
        npm ci 2>>"$EXAMPLE_DIR/build.err" || exit 1
      elif [ -f package.json ]; then
        npm install 2>>"$EXAMPLE_DIR/build.err" || exit 1
      else
        echo "build_only: no package.json in $dir" >> "$EXAMPLE_DIR/build.err"
        exit 1
      fi

      if [ -f package.json ] && jq -e '.scripts.build' package.json >/dev/null 2>&1; then
        (command -v bun >/dev/null 2>&1 && bun run build 2>>"$EXAMPLE_DIR/build.err") \
          || npm run build 2>>"$EXAMPLE_DIR/build.err" || exit 1
      elif [ -f tsconfig.json ]; then
        npx --yes tsc --noEmit 2>>"$EXAMPLE_DIR/build.err" || exit 1
      fi
    )
  }

  if [ -n "$SUBDIRS_JSON" ] && [ "$SUBDIRS_JSON" != "[]" ]; then
    n=$(printf '%s' "$SUBDIRS_JSON" | jq 'length')
    for ((i=0; i<n; i++)); do
      subdir=$(printf '%s' "$SUBDIRS_JSON" | jq -r ".[$i]")
      echo "build_only: building $subdir" >&2
      if ! build_one_ts_dir "$EXAMPLE_DIR/$subdir"; then
        STDERR_TAIL=$(tail_meaningful "$EXAMPLE_DIR/build.err")
        exit 0
      fi
    done
  else
    if ! build_one_ts_dir "$EXAMPLE_DIR"; then
      STDERR_TAIL=$(tail_meaningful build.err)
      exit 0
    fi
  fi

  STATUS="passing"
  exit 0
fi

if [ -f bun.lockb ] || [ -f bun.lock ]; then
  bun install 2>>install.err || exit 0
  bun add "@resonatehq/sdk@${SDK_VERSION}" 2>>install.err || exit 0
else
  (npm ci 2>>install.err || npm install 2>>install.err) || exit 0
  npm install --save-exact "@resonatehq/sdk@${SDK_VERSION}" 2>>install.err || exit 0
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
    STDERR_TAIL=$(tail_meaningful run.err)
  fi
fi
