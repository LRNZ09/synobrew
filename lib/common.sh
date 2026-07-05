#!/usr/bin/env bash
# lib/common.sh — pure helpers for synobrew. No side effects; safe to source.
# Every function is deterministic given its arguments (or stdin) and only echoes
# / returns status, so it can be unit-tested without a Synology.

sb_classify_arch() {
  # $1: machine string (uname -m). Echoes: supported | warn | blocked
  case "${1:-}" in
    x86_64|amd64) echo supported ;;
    aarch64|arm64) echo warn ;;
    *) echo blocked ;;
  esac
}

sb_version_ge() {
  # Return 0 iff $1 >= $2 as dotted-numeric versions.
  [ "${1:-}" = "${2:-}" ] && return 0
  local lower
  lower="$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)"
  [ "$lower" = "$2" ]
}

sb_dsm_tier() {
  # $1 major, $2 minor (integers). Echoes ok | warn | blocked.
  local maj="${1:-0}" min="${2:-0}"
  case "$maj" in ''|*[!0-9]*) maj=0 ;; esac
  case "$min" in ''|*[!0-9]*) min=0 ;; esac
  if [ "$maj" -gt 7 ]; then echo ok; return; fi
  if [ "$maj" -lt 7 ]; then echo blocked; return; fi
  if [ "$min" -ge 2 ]; then echo ok
  elif [ "$min" -eq 1 ]; then echo warn
  else echo blocked
  fi
}

sb_parse_glibc() {
  # $1: text (libc banner or `ldd --version`). Echoes first X.Y, or empty.
  printf '%s\n' "${1:-}" | grep -Eo '[0-9]+\.[0-9]+' | head -n1
}
