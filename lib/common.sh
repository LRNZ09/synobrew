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

sb_shell_from_path() {
  # $1: shell path (e.g. from $SHELL). Echoes bash|zsh|fish|sh|other.
  case "$(basename "${1:-}")" in
    bash) echo bash ;;
    zsh) echo zsh ;;
    fish) echo fish ;;
    sh|dash|ash) echo sh ;;
    *) echo other ;;
  esac
}

sb_rc_file() {
  # $1 shell, $2 home. Echoes the rc file to edit.
  case "${1:-}" in
    fish) echo "${2}/.config/fish/config.fish" ;;
    zsh) echo "${2}/.zshrc" ;;
    *) echo "${2}/.profile" ;;  # bash, sh, other -> login rcfile on DSM
  esac
}

sb_shellenv_line() {
  # $1 shell, $2 brew binary path. Echoes the exact line to append.
  case "${1:-}" in
    fish) echo "${2} shellenv fish | source" ;;
    *) echo "eval \"\$(${2} shellenv)\"" ;;
  esac
}

sb_env_line() {
  # $1 shell, $2 var name, $3 value. Echoes the exact rc line to persist an
  # environment variable (fish uses `set -gx`; POSIX shells use `export`).
  case "${1:-}" in
    fish) printf 'set -gx %s "%s"\n' "${2:-}" "${3:-}" ;;
    *)    printf 'export %s="%s"\n' "${2:-}" "${3:-}" ;;
  esac
}

sb_bak_name() {
  # $1 path, $2 epoch. Echoes the backup filename.
  echo "${1}.synobrew.bak-${2}"
}

sb_classify_state() {
  # $1 brew_at_std(0/1) $2 mount_present(0/1) $3 same_backing(0/1) $4 brew_elsewhere(0/1)
  if [ "${1:-0}" = 1 ]; then
    if [ "${2:-0}" = 1 ] && [ "${3:-0}" = 1 ]; then echo managed; else echo foreign-backing; fi
    return
  fi
  if [ "${4:-0}" = 1 ]; then echo foreign-prefix; return; fi
  echo fresh
}

sb_dev_inode() {
  # $1 path. Echoes "<dev>:<inode>" (GNU or BSD stat), empty if missing.
  [ -e "${1:-}" ] || return 0
  stat -c '%d:%i' "$1" 2>/dev/null || stat -f '%d:%i' "$1" 2>/dev/null || true
}
