#!/usr/bin/env bash
set -uo pipefail

EXAMPLE_DIR="${EXAMPLE_DIR:?required}"
EXAMPLE_NAME="${EXAMPLE_NAME:?required}"
SDK_VERSION="${SDK_VERSION:?required}"
KIND="${KIND:-script}"
ENTRY="${ENTRY:-python main.py}"
TIMEOUT_S="${TIMEOUT_S:-60}"
HEALTHY_AFTER_S="${HEALTHY_AFTER_S:-15}"
HEALTH_REGEX="${HEALTH_REGEX:-registered|ready|listening}"

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
    --arg sdk "py" \
    --arg sdk_version "$SDK_VERSION" \
    --arg status "$STATUS" \
    --argjson duration "$duration" \
    --arg stderr_tail "$STDERR_TAIL" \
    '{repo: $repo, sdk: $sdk, sdk_version: $sdk_version, status: $status, duration_s: $duration, stderr_tail: $stderr_tail}' \
    > "$WORKSPACE/result.json"
}
trap emit_result EXIT

cd "$EXAMPLE_DIR"

python -m venv .venv 2>>install.err || exit 0
. .venv/bin/activate

if [ -f pyproject.toml ]; then
  (pip install -e . 2>>install.err || pip install . 2>>install.err) || exit 0
elif [ -f requirements.txt ]; then
  pip install -r requirements.txt 2>>install.err || exit 0
else
  echo "no pyproject.toml or requirements.txt" >> install.err
  exit 0
fi

pip install --upgrade "resonate-sdk==${SDK_VERSION}" 2>>install.err || exit 0

STATUS="runtime_failed"

if [ "$KIND" = "worker" ]; then
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
