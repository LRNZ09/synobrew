#!/usr/bin/env bash
# restore.sh — idempotently (re)create synobrew's DSM shims + prefix bind mount.
# Runs from install.sh AND from the DSM boot-up Task Scheduler task (as root).
# Self-contained: at boot $HOME is unset, so it reads its absolute config from a
# sibling synobrew.conf (written by install.sh). Assumes install.sh already made
# one-time backups of any pre-existing /usr/bin/ldd or /etc/os-release.
set -euo pipefail

DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -r "${DIR}/synobrew.conf" ] && . "${DIR}/synobrew.conf"

SB_PREFIX_MOUNT="${SB_PREFIX_MOUNT:-/home/linuxbrew}"
SB_PREFIX_STORE="${SB_PREFIX_STORE:-${HOME:-/root}/.tools/synobrew/prefix}"
SB_OWNER="${SB_OWNER:-root:root}"
SB_LDD="${SB_LDD:-/usr/bin/ldd}"
SB_OSRELEASE="${SB_OSRELEASE:-/etc/os-release}"
SB_LIBC="${SB_LIBC:-/usr/lib/libc.so.6}"
SB_DSM_VERSION_FILE="${SB_DSM_VERSION_FILE:-/etc.defaults/VERSION}"
SB_MOUNT="${SB_MOUNT:-mount}"

log() { printf 'synobrew(restore): %s\n' "$*" >&2; }
run() { if $DRY_RUN; then printf '[dry-run] %s\n' "$*" >&2; else "$@"; fi; }

ensure_mount() {
  run mkdir -p "$SB_PREFIX_MOUNT" "$SB_PREFIX_STORE"
  if mountpoint -q "$SB_PREFIX_MOUNT" 2>/dev/null; then
    log "already mounted: $SB_PREFIX_MOUNT"
  else
    run "$SB_MOUNT" -o bind "$SB_PREFIX_STORE" "$SB_PREFIX_MOUNT"
    log "bind-mounted $SB_PREFIX_STORE -> $SB_PREFIX_MOUNT"
  fi
  run chown "$SB_OWNER" "$SB_PREFIX_MOUNT"
}

ensure_ldd() {
  if [ -x "$SB_LDD" ]; then
    if "$SB_LDD" --version 2>/dev/null | grep -q 'synobrew'; then
      log "ldd shim already present: $SB_LDD"; return
    fi
    if "$SB_LDD" --version 2>/dev/null | grep -Eq '[0-9]+\.[0-9]+'; then
      log "keeping existing non-synobrew ldd: $SB_LDD"; return
    fi
  fi
  if $DRY_RUN; then printf '[dry-run] write ldd shim -> %s\n' "$SB_LDD" >&2; return; fi
  cat > "$SB_LDD" <<EOF
#!/bin/sh
# synobrew ldd shim — Homebrew probes 'ldd --version' for glibc; DSM has no ldd.
v=\$(${SB_LIBC} 2>/dev/null | sed -n 's/.*version \\([0-9][0-9]*\\.[0-9][0-9]*\\).*/\\1/p' | head -n1)
[ -n "\$v" ] || v=2.20
echo "ldd (synobrew shim) \$v"
EOF
  chmod 755 "$SB_LDD"
  log "wrote ldd shim: $SB_LDD"
}

ensure_osrelease() {
  if $DRY_RUN; then printf '[dry-run] write os-release -> %s\n' "$SB_OSRELEASE" >&2; return; fi
  local pv
  # shellcheck source=/dev/null
  pv="$( . "$SB_DSM_VERSION_FILE" 2>/dev/null; echo "${productversion:-7}" )"
  cat > "$SB_OSRELEASE" <<EOF
NAME="Synology DSM"
ID=synology
ID_LIKE=linux
PRETTY_NAME="Synology DSM ${pv}"
VERSION="${pv}"
VERSION_ID="${pv}"
EOF
  log "wrote os-release: $SB_OSRELEASE (DSM ${pv})"
}

main() {
  ensure_mount
  ensure_ldd
  ensure_osrelease
  log "restore complete"
}
main
