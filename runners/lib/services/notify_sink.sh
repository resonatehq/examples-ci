#!/usr/bin/env bash
# Sourced when an example's manifest entry has `notify_sink` in its `services`
# list. Starts a tiny Python HTTP server that 200s any POST. Exports
# NOTIFY_URL so manifest entries can use it as an invoke arg.

NOTIFY_SINK_PORT="${NOTIFY_SINK_PORT:-9999}"
NOTIFY_SINK_HOST="${NOTIFY_SINK_HOST:-127.0.0.1}"

start_notify_sink() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "notify_sink: python3 not in PATH" >&2
    return 1
  fi

  local script
  script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/notify_sink.py"
  if [ ! -f "$script" ]; then
    echo "notify_sink: $script missing" >&2
    return 1
  fi

  NOTIFY_SINK_HOST="$NOTIFY_SINK_HOST" NOTIFY_SINK_PORT="$NOTIFY_SINK_PORT" \
    python3 "$script" > /tmp/notify-sink.log 2>&1 &
  NOTIFY_SINK_PID=$!
  export NOTIFY_SINK_PID

  local i
  for i in $(seq 1 30); do
    if (echo > "/dev/tcp/$NOTIFY_SINK_HOST/$NOTIFY_SINK_PORT") 2>/dev/null; then
      if curl -sf "http://$NOTIFY_SINK_HOST:$NOTIFY_SINK_PORT/" >/dev/null 2>&1; then
        echo "notify_sink: ready (pid=$NOTIFY_SINK_PID port=$NOTIFY_SINK_PORT)" >&2
        export NOTIFY_URL="http://$NOTIFY_SINK_HOST:$NOTIFY_SINK_PORT/"
        return 0
      fi
    fi
    if ! kill -0 "$NOTIFY_SINK_PID" 2>/dev/null; then
      echo "notify_sink: process exited before becoming ready" >&2
      cat /tmp/notify-sink.log >&2 2>/dev/null || true
      return 1
    fi
    sleep 0.25
  done

  echo "notify_sink: did not become ready within 8s" >&2
  cat /tmp/notify-sink.log >&2 2>/dev/null || true
  return 1
}

stop_notify_sink() {
  if [ -n "${NOTIFY_SINK_PID:-}" ]; then
    kill -TERM "$NOTIFY_SINK_PID" 2>/dev/null || true
    sleep 1
    kill -KILL "$NOTIFY_SINK_PID" 2>/dev/null || true
  fi
}
