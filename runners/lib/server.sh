#!/usr/bin/env bash
# Sourced by per-SDK runner scripts when REQUIRES_SERVER=true.
# Downloads + spawns `resonate dev` (in-memory mode, port 8001) on the runner.
# Examples connect via their hardcoded http://localhost:8001 — no URL injection.

start_resonate_server() {
  local arch os tag url
  case "$(uname -m)" in
    x86_64|amd64) arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    *) echo "unsupported arch: $(uname -m)" >&2; return 1 ;;
  esac
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"

  tag=$(curl -sf https://api.github.com/repos/resonatehq/resonate/releases/latest | jq -r .tag_name)
  if [ -z "$tag" ] || [ "$tag" = "null" ]; then
    echo "resonate latest-release lookup failed" >&2
    return 1
  fi

  url="https://github.com/resonatehq/resonate/releases/download/${tag}/resonate_${os}_${arch}.tar.gz"
  if ! curl -sLf "$url" | tar xz -C /tmp resonate 2>/dev/null; then
    echo "resonate binary download failed: $url" >&2
    return 1
  fi
  chmod +x /tmp/resonate

  /tmp/resonate dev > /tmp/resonate.log 2>&1 &
  RESONATE_SERVER_PID=$!
  export RESONATE_SERVER_PID

  local i
  for i in $(seq 1 30); do
    if curl -sf http://localhost:8001/ >/dev/null 2>&1; then
      echo "resonate server ready (tag=$tag pid=$RESONATE_SERVER_PID)" >&2
      return 0
    fi
    sleep 0.5
  done

  echo "resonate server did not become healthy within 15s" >&2
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
