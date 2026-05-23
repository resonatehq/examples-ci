#!/usr/bin/env bash
# Sourced by per-SDK runners. Dispatches start_<kind>/stop_<kind> for each
# service named in the manifest entry's `services:` list. The list is passed
# in via $SERVICES_JSON (JSON array of strings, e.g. '["redpanda"]').
#
# Adding a new service kind = one new file at services/<kind>.sh that
# exports start_<kind>() and stop_<kind>().

# Absolute path: the per-SDK runner sources this at workspace root then
# `cd`s into $EXAMPLE_DIR, so a relative path here would 404 at call time.
SERVICES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/services"
SERVICES_STARTED=()

start_services() {
  local json="${SERVICES_JSON:-}"
  [ -z "$json" ] && return 0
  [ "$json" = "null" ] && return 0
  [ "$json" = "[]" ] && return 0

  local kinds kind helper
  kinds=$(printf '%s' "$json" | jq -r '.[]')
  while IFS= read -r kind; do
    [ -z "$kind" ] && continue
    helper="$SERVICES_DIR/${kind}.sh"
    if [ ! -f "$helper" ]; then
      echo "services: unknown kind '$kind' (no $helper)" >&2
      return 1
    fi
    # shellcheck source=/dev/null
    . "$helper"
    if ! "start_${kind}"; then
      echo "services: start_${kind} failed" >&2
      return 1
    fi
    SERVICES_STARTED+=("$kind")
  done <<< "$kinds"
}

stop_services() {
  local kind
  for kind in "${SERVICES_STARTED[@]}"; do
    "stop_${kind}" 2>/dev/null || true
  done
  SERVICES_STARTED=()
}
