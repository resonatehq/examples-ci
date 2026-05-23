#!/usr/bin/env bash
# Sourced when an example's manifest entry has `tigerbeetle` in its `services`
# list. Downloads the latest TigerBeetle release binary, formats a fresh
# single-replica data file in /tmp, and starts the server on port 3000.
#
# Symlinks the binary into $EXAMPLE_DIR/bin/tigerbeetle so example scripts
# that reference ./bin/tigerbeetle (e.g. the create-account example's
# README + scripts/setup.sh) work unchanged.

TIGERBEETLE_PORT="${TIGERBEETLE_PORT:-3000}"
TIGERBEETLE_DATA="${TIGERBEETLE_DATA:-/tmp/tb-0-0.tigerbeetle}"

start_tigerbeetle() {
  local arch os tag asset url
  case "$(uname -m)" in
    x86_64|amd64) arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    *) echo "tigerbeetle: unsupported arch $(uname -m)" >&2; return 1 ;;
  esac
  case "$(uname -s)" in
    Linux)  asset="tigerbeetle-${arch}-linux.zip" ;;
    Darwin) asset="tigerbeetle-universal-macos.zip" ;;
    *) echo "tigerbeetle: unsupported OS $(uname -s)" >&2; return 1 ;;
  esac

  local attempt
  for attempt in 1 2 3; do
    tag=$(curl -sf --retry 2 --retry-delay 1 \
      "https://api.github.com/repos/tigerbeetle/tigerbeetle/releases/latest" | jq -r .tag_name 2>/dev/null)
    if [ -n "$tag" ] && [ "$tag" != "null" ]; then break; fi
    [ "$attempt" -lt 3 ] && sleep 2
  done
  if [ -z "$tag" ] || [ "$tag" = "null" ]; then
    echo "tigerbeetle: latest-release lookup failed" >&2
    return 1
  fi

  url="https://github.com/tigerbeetle/tigerbeetle/releases/download/${tag}/${asset}"
  rm -rf /tmp/tb-bin && mkdir -p /tmp/tb-bin
  for attempt in 1 2 3; do
    if curl -sLf --retry 2 --retry-delay 1 "$url" -o /tmp/tb.zip; then
      if unzip -o -q /tmp/tb.zip -d /tmp/tb-bin; then
        break
      fi
    fi
    [ "$attempt" -lt 3 ] && sleep 2
  done
  if [ ! -f /tmp/tb-bin/tigerbeetle ]; then
    echo "tigerbeetle: download/unzip failed for $url" >&2
    return 1
  fi
  chmod +x /tmp/tb-bin/tigerbeetle
  TIGERBEETLE_BIN=/tmp/tb-bin/tigerbeetle
  export TIGERBEETLE_BIN

  rm -f "$TIGERBEETLE_DATA"
  if ! "$TIGERBEETLE_BIN" format \
      --cluster=0 --replica=0 --replica-count=1 \
      "$TIGERBEETLE_DATA" > /tmp/tb.format.log 2>&1; then
    echo "tigerbeetle: format failed" >&2
    cat /tmp/tb.format.log >&2 2>/dev/null || true
    return 1
  fi

  # Many example READMEs (incl. tigerbeetle-account-creation-ts) expect the
  # binary at ./bin/tigerbeetle relative to the example. Symlink so the
  # example's own scripts work without monkey-patching.
  if [ -n "${EXAMPLE_DIR:-}" ] && [ -d "$EXAMPLE_DIR" ]; then
    mkdir -p "$EXAMPLE_DIR/bin"
    ln -sf "$TIGERBEETLE_BIN" "$EXAMPLE_DIR/bin/tigerbeetle"
  fi

  "$TIGERBEETLE_BIN" start --addresses="$TIGERBEETLE_PORT" "$TIGERBEETLE_DATA" \
    > /tmp/tb.log 2>&1 &
  TIGERBEETLE_PID=$!
  export TIGERBEETLE_PID

  # Wait for the port to open. TigerBeetle binds late in startup, so port-open
  # is a faithful "ready to accept clients" signal here (unlike Redpanda).
  local i
  for i in $(seq 1 30); do
    if (echo > "/dev/tcp/127.0.0.1/$TIGERBEETLE_PORT") 2>/dev/null; then
      echo "tigerbeetle: ready (tag=$tag port=$TIGERBEETLE_PORT pid=$TIGERBEETLE_PID)" >&2
      return 0
    fi
    if ! kill -0 "$TIGERBEETLE_PID" 2>/dev/null; then
      echo "tigerbeetle: process exited before port opened" >&2
      cat /tmp/tb.log >&2 2>/dev/null || true
      return 1
    fi
    sleep 0.5
  done

  echo "tigerbeetle: port $TIGERBEETLE_PORT did not open within 15s" >&2
  cat /tmp/tb.log >&2 2>/dev/null || true
  return 1
}

stop_tigerbeetle() {
  if [ -n "${TIGERBEETLE_PID:-}" ]; then
    kill -TERM "$TIGERBEETLE_PID" 2>/dev/null || true
    sleep 1
    kill -KILL "$TIGERBEETLE_PID" 2>/dev/null || true
  fi
}
