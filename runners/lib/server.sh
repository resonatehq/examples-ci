#!/usr/bin/env bash
# Sourced by per-SDK runner scripts when REQUIRES_SERVER=true.
# Downloads + spawns the appropriate Resonate server binary, in-memory mode.
#
# SERVER_KIND selects which server:
#   rust       (default) — resonatehq/resonate (current). Unified port 8001.
#                          TS/RS SDKs and updated Py SDKs speak this protocol.
#   legacy_go             — resonatehq/resonate-legacy-server. Two ports:
#                          API on 8001 + poll on 8002. Python SDK 0.6.7
#                          targets this protocol — the new SDK migration
#                          hasn't shipped yet.
#
# Both binaries name themselves `resonate` and accept `resonate dev` to start
# in development mode. Asset naming is identical
# (`resonate_${os}_${arch}.tar.gz`) so the install path is shared.

start_resonate_server() {
  local arch os tag url server_kind ready_regex repo
  case "$(uname -m)" in
    x86_64|amd64) arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    *) echo "unsupported arch: $(uname -m)" >&2; return 1 ;;
  esac
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"

  server_kind="${SERVER_KIND:-rust}"
  case "$server_kind" in
    rust)
      repo="resonatehq/resonate"
      # The Rust server logs `Server listening bind=... port=8001` after bind+listen.
      ready_regex="Server listening"
      ;;
    legacy_go|legacy)
      repo="resonatehq/resonate-legacy-server"
      # The Go server logs `starting http server` AND `starting poll server` —
      # http is the last critical service to come up before workers can connect.
      ready_regex="starting http server"
      ;;
    *)
      echo "unknown SERVER_KIND: $server_kind (want rust or legacy_go)" >&2
      return 1
      ;;
  esac

  tag=$(curl -sf "https://api.github.com/repos/${repo}/releases/latest" | jq -r .tag_name)
  if [ -z "$tag" ] || [ "$tag" = "null" ]; then
    echo "${repo} latest-release lookup failed" >&2
    return 1
  fi

  url="https://github.com/${repo}/releases/download/${tag}/resonate_${os}_${arch}.tar.gz"
  if ! curl -sLf "$url" | tar xz -C /tmp resonate 2>/dev/null; then
    echo "resonate binary download failed: $url" >&2
    return 1
  fi
  chmod +x /tmp/resonate

  /tmp/resonate dev > /tmp/resonate.log 2>&1 &
  RESONATE_SERVER_PID=$!
  export RESONATE_SERVER_PID

  # Detect readiness via the server's own log line — robust against HTTP-route
  # changes and works identically for both server kinds.
  local i
  for i in $(seq 1 60); do
    if grep -q "$ready_regex" /tmp/resonate.log 2>/dev/null; then
      echo "resonate server ready (kind=$server_kind tag=$tag pid=$RESONATE_SERVER_PID)" >&2
      return 0
    fi
    if ! kill -0 "$RESONATE_SERVER_PID" 2>/dev/null; then
      echo "resonate server exited before logging '$ready_regex'" >&2
      cat /tmp/resonate.log >&2 2>/dev/null || true
      return 1
    fi
    sleep 0.25
  done

  echo "resonate server did not log '$ready_regex' within 15s (kind=$server_kind)" >&2
  echo "--- /tmp/resonate.log ---" >&2
  cat /tmp/resonate.log >&2 2>/dev/null || true
  return 1
}

stop_resonate_server() {
  if [ -n "${RESONATE_SERVER_PID:-}" ]; then
    kill -TERM "$RESONATE_SERVER_PID" 2>/dev/null || true
    sleep 1
    kill -KILL "$RESONATE_SERVER_PID" 2>/dev/null || true
  fi
}
