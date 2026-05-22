#!/usr/bin/env bash
# Shared helpers sourced by per-SDK runners and multi.sh.

# Capture the last meaningful stderr lines for `result.json#stderr_tail`.
#
# The naive `tail -c 4096` byte-tail favors Rust panics with verbose
# backtraces — the last 4 KB is often just
# `note: run with RUST_BACKTRACE=1 environment variable to display a
# backtrace` plus blank lines, hiding the actual panic message above it.
# Instead, take the last 10 non-empty lines (after a generous 50-line
# window to keep the work bounded). That keeps `compile_failed` Rust
# errors, multi-line Python tracebacks, and TS stack frames all
# intelligible without the artifact-download dance.
tail_meaningful() {
  local file="$1"
  [ -f "$file" ] || return 0
  # Filter non-empty lines first, then take the last 10. Filtering AFTER
  # tail discards meaningful lines when the file ends with many blanks
  # (Rust panics commonly trail dozens of empty lines).
  awk 'NF' "$file" 2>/dev/null | tail -n 10
}
