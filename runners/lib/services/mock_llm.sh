#!/usr/bin/env bash
# Sourced when an example's manifest entry has `mock_llm` in its `services`
# list. Starts a Python HTTP server that mimics the OpenAI + Anthropic
# chat APIs with canned responses. After start, exports the BASE_URL +
# dummy API_KEY env vars so the example's SDK client redirects here.

MOCK_LLM_PORT="${MOCK_LLM_PORT:-8080}"
MOCK_LLM_HOST="${MOCK_LLM_HOST:-127.0.0.1}"

start_mock_llm() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "mock_llm: python3 not in PATH" >&2
    return 1
  fi

  local script
  script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/mock_llm.py"
  if [ ! -f "$script" ]; then
    echo "mock_llm: $script missing" >&2
    return 1
  fi

  MOCK_LLM_HOST="$MOCK_LLM_HOST" MOCK_LLM_PORT="$MOCK_LLM_PORT" \
    python3 "$script" > /tmp/mock-llm.log 2>&1 &
  MOCK_LLM_PID=$!
  export MOCK_LLM_PID

  # Wait for the port to open. Fast — Python http.server binds immediately.
  local i
  for i in $(seq 1 30); do
    if (echo > "/dev/tcp/$MOCK_LLM_HOST/$MOCK_LLM_PORT") 2>/dev/null; then
      # Confirm the handler is wired up — bare port-open isn't enough if the
      # interpreter trapped at startup.
      if curl -sf "http://$MOCK_LLM_HOST:$MOCK_LLM_PORT/" >/dev/null 2>&1; then
        echo "mock_llm: ready (pid=$MOCK_LLM_PID port=$MOCK_LLM_PORT)" >&2
        # Point both SDKs at the mock + give them a dummy key so the
        # constructor-time env-presence guards don't trip.
        export OPENAI_BASE_URL="http://$MOCK_LLM_HOST:$MOCK_LLM_PORT/v1"
        export OPENAI_API_KEY="mock-openai-key"
        export ANTHROPIC_BASE_URL="http://$MOCK_LLM_HOST:$MOCK_LLM_PORT"
        export ANTHROPIC_API_KEY="mock-anthropic-key"
        return 0
      fi
    fi
    if ! kill -0 "$MOCK_LLM_PID" 2>/dev/null; then
      echo "mock_llm: process exited before becoming ready" >&2
      cat /tmp/mock-llm.log >&2 2>/dev/null || true
      return 1
    fi
    sleep 0.25
  done

  echo "mock_llm: did not become ready within 8s" >&2
  cat /tmp/mock-llm.log >&2 2>/dev/null || true
  return 1
}

stop_mock_llm() {
  if [ -n "${MOCK_LLM_PID:-}" ]; then
    kill -TERM "$MOCK_LLM_PID" 2>/dev/null || true
    sleep 1
    kill -KILL "$MOCK_LLM_PID" 2>/dev/null || true
  fi
}
