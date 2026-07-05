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
