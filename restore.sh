#!/usr/bin/env bash
# restore.sh — idempotently (re)create synobrew's DSM shims + prefix bind mount.
# Run by install.sh (as root, via sudo) to set up the mount + ldd/os-release
# shims. The DSM boot task does NOT run this script: reboot persistence is a
# self-contained inline `mount` command in the Task Scheduler entry (root-only
# config), so no user-owned file is executed as root at boot. Config comes from
# the SB_* env install.sh passes through sudo (production defaults below).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"

DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

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
  # Skip if the store is already bind-mounted at the prefix. Detect via dev:inode
  # equality (a bind mount makes the two paths the same directory), NOT `mountpoint`,
  # which is unreliable/absent on DSM's busybox userland and can't see bind mounts
  # there — so a re-run would otherwise stack a duplicate mount every time.
  local mount_di store_di
  mount_di="$(sb_dev_inode "$SB_PREFIX_MOUNT")"
  store_di="$(sb_dev_inode "$SB_PREFIX_STORE")"
  if [ -n "$mount_di" ] && [ "$mount_di" = "$store_di" ]; then
    log "already mounted: $SB_PREFIX_MOUNT"
  else
    run "$SB_MOUNT" -o bind "$SB_PREFIX_STORE" "$SB_PREFIX_MOUNT"
    log "bind-mounted $SB_PREFIX_STORE -> $SB_PREFIX_MOUNT"
  fi
  run chown "$SB_OWNER" "$SB_PREFIX_MOUNT"
  # The store must be user-owned too — brew owns its prefix.
  run chown "$SB_OWNER" "$SB_PREFIX_STORE"
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
  # Already our shim (marker present)? no-op — spec §5 "no-op when already correct".
  if [ -e "$SB_OSRELEASE" ] && grep -q 'synobrew os-release shim' "$SB_OSRELEASE" 2>/dev/null; then
    log "os-release shim already present: $SB_OSRELEASE"; return
  fi
  if $DRY_RUN; then printf '[dry-run] write os-release -> %s\n' "$SB_OSRELEASE" >&2; return; fi
  # A foreign (non-synobrew) os-release we have not backed up yet -> preserve it
  # once. A prior .bak means install.sh's backup_if_present or an earlier boot
  # already saved the original, so we don't accumulate a backup every reboot.
  if [ -e "$SB_OSRELEASE" ]; then
    local had_bak=false b
    for b in "$SB_OSRELEASE".synobrew.bak-*; do [ -e "$b" ] && { had_bak=true; break; }; done
    if ! $had_bak; then
      cp -a "$SB_OSRELEASE" "${SB_OSRELEASE}.synobrew.bak-$(date +%s)" 2>/dev/null || true
      log "backed up existing os-release before overwriting: $SB_OSRELEASE"
    fi
  fi
  local pv
  # shellcheck source=/dev/null
  pv="$( . "$SB_DSM_VERSION_FILE" 2>/dev/null; echo "${productversion:-7}" )"
  cat > "$SB_OSRELEASE" <<EOF
# synobrew os-release shim
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
