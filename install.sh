#!/usr/bin/env bash
# install.sh — install-or-repair Homebrew on Synology DSM 7.x. Run over SSH as a
# non-root admin user. Auditable by design; see README.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"

DRY_RUN=false
ASSUME_YES=false

# --- injectable paths / commands (production defaults) ---
SB_HOME="${SB_HOME:-$HOME}"
SB_PREFIX_MOUNT="${SB_PREFIX_MOUNT:-/home/linuxbrew}"
SB_PREFIX_STORE="${SB_PREFIX_STORE:-$SB_HOME/.tools/synobrew/prefix}"
SB_TOOLS_DIR="${SB_TOOLS_DIR:-$SB_HOME/.tools/synobrew}"
SB_LDD="${SB_LDD:-/usr/bin/ldd}"
SB_OSRELEASE="${SB_OSRELEASE:-/etc/os-release}"
SB_DSM_VERSION_FILE="${SB_DSM_VERSION_FILE:-/etc.defaults/VERSION}"
SB_LIBC="${SB_LIBC:-/usr/lib/libc.so.6}"
SB_HOMES_DIR="${SB_HOMES_DIR:-/var/services/homes}"
SB_MOUNT="${SB_MOUNT:-mount}"
SB_SUDO="${SB_SUDO:-sudo}"
SB_UNAME_M="${SB_UNAME_M:-$(uname -m)}"
SB_GIT="${SB_GIT:-git}"
SB_BREW_INSTALL_URL="${SB_BREW_INSTALL_URL:-https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh}"
SB_EUID="${SB_EUID:-$(id -u)}"
# Forward-declared for Tasks 6/7; tests point these at stubs. The ${X:-...}
# self-default counts as a read, so shellcheck does not flag SC2034.
SB_BREW="${SB_BREW:-brew}"                 # foreign-prefix probe (Task 6)
SB_CURL="${SB_CURL:-curl}"                 # Homebrew installer fetch (Task 7)
SB_RSYNC="${SB_RSYNC:-rsync}"              # cross-fs prefix copy (Task 7)

log()  { printf 'synobrew: %s\n' "$*" >&2; }
warn() { printf 'synobrew: WARNING: %s\n' "$*" >&2; }
die()  { printf 'synobrew: ERROR: %s\n' "$*" >&2; exit 1; }
run()  { if $DRY_RUN; then printf '[dry-run] %s\n' "$*" >&2; else "$@"; fi; }

confirm() {
  # $1: prompt. Returns 0 to proceed. --yes / --dry-run auto-proceed.
  $ASSUME_YES && return 0
  $DRY_RUN && return 0
  printf 'synobrew: %s [y/N] ' "$1" >&2
  local reply; read -r reply
  case "$reply" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

usage() {
  cat <<'EOF'
Usage: install.sh [--dry-run] [--yes] [-h|--help]

Install or repair Homebrew (Linuxbrew) on Synology DSM 7.x.

  --dry-run   Print every privileged/mutating action without executing it.
  --yes       Skip the confirmation prompt (non-interactive).
  -h, --help  Show this help.

Run as a non-root user in the DSM 'administrators' group (has sudo).
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=true ;;
      --yes|-y) ASSUME_YES=true ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown argument: $1 (use --help)" ;;
    esac
    shift
  done
}

dsm_fields() {
  # Echoes "MAJOR MINOR PRODUCT" from the DSM VERSION file (0 0 unknown if absent).
  local maj=0 min=0 prod=unknown
  if [ -r "$SB_DSM_VERSION_FILE" ]; then
    # shellcheck source=/dev/null
    maj="$( . "$SB_DSM_VERSION_FILE" 2>/dev/null; echo "${majorversion:-0}" )"
    # shellcheck source=/dev/null
    min="$( . "$SB_DSM_VERSION_FILE" 2>/dev/null; echo "${minorversion:-0}" )"
    # shellcheck source=/dev/null
    prod="$( . "$SB_DSM_VERSION_FILE" 2>/dev/null; echo "${productversion:-unknown}" )"
  fi
  echo "$maj $min $prod"
}

preflight() {
  [ "$SB_EUID" -ne 0 ] || die "do not run as root; run as a non-root admin user (Homebrew refuses root)."

  local arch; arch="$(sb_classify_arch "$SB_UNAME_M")"
  case "$arch" in
    supported) log "architecture $SB_UNAME_M: supported." ;;
    warn) warn "architecture $SB_UNAME_M: supported but Linux bottles are thin; many formulae build from source and may OOM on low-RAM units." ;;
    blocked) die "architecture $SB_UNAME_M is not supported by Homebrew (need x86_64 or aarch64)." ;;
  esac

  read -r maj min prod <<EOF
$(dsm_fields)
EOF
  local tier; tier="$(sb_dsm_tier "$maj" "$min")"
  case "$tier" in
    ok) log "DSM $prod: supported." ;;
    warn) warn "DSM $prod: 7.1 is best-effort; 7.2+ recommended." ;;
    blocked) die "DSM $prod is too old; DSM 7.1+ required (7.2+ recommended)." ;;
  esac

  if [ ! -d "$SB_HOMES_DIR" ] && [ ! -d "$SB_HOME" ]; then
    die "user home service not enabled ($SB_HOMES_DIR missing). Enable Control Panel > User & Group > Advanced > User Home, then re-run."
  fi

  if ! command -v "$SB_GIT" >/dev/null 2>&1; then
    warn "git not found. Install it via Package Center (SynoCommunity), or run 'brew install git' after setup. Continuing."
  fi

  if [ -x "$SB_LIBC" ]; then
    # Trailing `|| true`: sb_parse_glibc returns non-zero when libc emits no
    # parseable version (grep no-match under `pipefail`). The glibc check is
    # informational only (never a hard block), so it must not abort the
    # installer under `set -e`.
    local g; g="$(sb_parse_glibc "$("$SB_LIBC" 2>/dev/null || true)")" || true
    if [ -n "$g" ]; then
      log "glibc detected: $g (floor 2.13; informational)."
    fi
  fi
}

detect_state() {
  local brew_std=0 mount=0 same=0 elsewhere=0
  [ -x "${SB_PREFIX_MOUNT}/.linuxbrew/bin/brew" ] && brew_std=1
  if mountpoint -q "$SB_PREFIX_MOUNT" 2>/dev/null; then mount=1; fi
  if [ "$mount" = 1 ] && \
     [ -n "$(sb_dev_inode "$SB_PREFIX_MOUNT")" ] && \
     [ "$(sb_dev_inode "$SB_PREFIX_MOUNT")" = "$(sb_dev_inode "$SB_PREFIX_STORE")" ]; then
    same=1
  fi
  # Foreign-prefix probe uses the injectable SB_BREW (not a bare `command -v
  # brew`) so tests can neutralize it (SB_BREW=$SANDBOX/no-such-brew); hosts
  # that already have Homebrew on PATH would otherwise flip fresh -> foreign-prefix.
  if [ "$brew_std" = 0 ] && command -v "$SB_BREW" >/dev/null 2>&1; then elsewhere=1; fi
  sb_classify_state "$brew_std" "$mount" "$same" "$elsewhere"
}

SB_OWNER="${SB_OWNER:-$(id -un):$(id -gn)}"
# Owner for the boot-executed artifacts (restore.sh + synobrew.conf + their dir).
# They are run / sourced by root at boot, so they must be root-owned and NOT
# user-writable — otherwise a write as the invoking user is arbitrary code
# execution as root at the next boot. Injectable so the same-user test sudo stub
# can chown to itself.
SB_ROOT_OWNER="${SB_ROOT_OWNER:-root:root}"
SB_EPOCH="${SB_EPOCH:-$(date +%s)}"
# Sudo keep-alive refresh cadence (seconds). Injectable so tests can shrink it:
# the keep-alive's `sleep` is orphaned when we kill the subshell at exit, and a
# pipe-capturing harness (bats) waits on it — a low value keeps the suite fast.
SB_KEEPALIVE_INTERVAL="${SB_KEEPALIVE_INTERVAL:-50}"

backup_if_present() {
  # $1 path: if it exists and is not already our shim/file, copy to a .bak.
  [ -e "$1" ] || return 0
  local bak; bak="$(sb_bak_name "$1" "$SB_EPOCH")"
  run cp -a "$1" "$bak"
  log "backed up $1 -> $bak"
}

apply_shims() {
  backup_if_present "$SB_LDD"
  backup_if_present "$SB_OSRELEASE"
  local flag=""; $DRY_RUN && flag="--dry-run"
  # Pass SB_* through sudo via `sudo env ...`: sudo's default env_reset would
  # otherwise strip them and restore.sh would use root's defaults.
  run "$SB_SUDO" env \
    SB_PREFIX_MOUNT="$SB_PREFIX_MOUNT" SB_PREFIX_STORE="$SB_PREFIX_STORE" \
    SB_OWNER="$SB_OWNER" SB_LDD="$SB_LDD" SB_OSRELEASE="$SB_OSRELEASE" \
    SB_LIBC="$SB_LIBC" SB_DSM_VERSION_FILE="$SB_DSM_VERSION_FILE" SB_MOUNT="$SB_MOUNT" \
    bash "${SCRIPT_DIR}/restore.sh" $flag
}

migrate_prefix() {
  # Copy the live prefix (seen through the current mount/dir) into the new store,
  # then re-point the mount. Safe: the logical path never changes.
  #
  # Deliberate, documented deviation from spec §4a's same-fs `mv` optimization:
  # we rsync FROM the mounted view instead of resolving the bind mount's real
  # backing dir and `mv`-ing it. This handles both the bind-mount and
  # plain-dir foreign cases with one code path and is easier to audit.
  local mnt="$SB_PREFIX_MOUNT" store="$SB_PREFIX_STORE"
  if pgrep -x brew >/dev/null 2>&1; then die "a 'brew' process is running; stop it and retry."; fi
  [ ! -e "${store}/.linuxbrew" ] || die "target store ${store}/.linuxbrew already exists; move it aside and retry (never clobbered)."
  log "migrating existing prefix into ${store} (a snapshot first is recommended)."
  run mkdir -p "${store}/.linuxbrew"
  run "$SB_RSYNC" -aHAX --numeric-ids "${mnt}/.linuxbrew/" "${store}/.linuxbrew/"
  if ! $DRY_RUN; then
    [ -x "${store}/.linuxbrew/bin/brew" ] || die "migration copy failed: no brew at ${store}/.linuxbrew/bin/brew"
  fi
  if mountpoint -q "$mnt" 2>/dev/null; then
    run "$SB_SUDO" umount "$mnt" || run "$SB_SUDO" umount -l "$mnt"
  elif [ -d "${mnt}/.linuxbrew" ]; then
    run mv "${mnt}/.linuxbrew" "${mnt}/.linuxbrew.synobrew-old-${SB_EPOCH}"
    log "old prefix left at ${mnt}/.linuxbrew.synobrew-old-${SB_EPOCH} for manual removal."
  fi
}

install_persistence() {
  # restore.sh + synobrew.conf are executed / sourced by root at boot, so both
  # they and their directory must be root-owned and not user-writable — otherwise
  # a write as the invoking user would run as root at the next boot. Install them
  # via sudo with SB_ROOT_OWNER (root in production; the test user under the
  # same-user sudo stub). The prefix store beneath this dir stays user-owned
  # (restore.sh chowns it) since brew must own its prefix and never executes it.
  local o="${SB_ROOT_OWNER%%:*}" g="${SB_ROOT_OWNER##*:}"
  run "$SB_SUDO" install -d -o "$o" -g "$g" -m 755 "$SB_TOOLS_DIR"
  run "$SB_SUDO" install -o "$o" -g "$g" -m 755 "${SCRIPT_DIR}/restore.sh" "${SB_TOOLS_DIR}/restore.sh"
  # pwd -P resolves the DSM homes symlink (/var/services/homes -> /volume1/homes)
  # so the baked path is stable at boot when root has no $HOME; fall back to the
  # literal path when the dir does not exist yet (e.g. --dry-run).
  local abs_store; abs_store="$(cd "$SB_PREFIX_STORE" 2>/dev/null && pwd -P || echo "$SB_PREFIX_STORE")"
  if $DRY_RUN; then
    log "[dry-run] install root-owned ${SB_TOOLS_DIR}/synobrew.conf (SB_PREFIX_STORE=$abs_store, SB_OWNER=$SB_OWNER)"
  else
    local tmp_conf; tmp_conf="$(mktemp)"
    cat > "$tmp_conf" <<EOF
# Generated by synobrew install.sh — read by restore.sh at boot (root has no \$HOME).
# Root-owned; do NOT make user-writable (it is sourced by the root boot task).
SB_PREFIX_STORE="${abs_store}"
SB_PREFIX_MOUNT="${SB_PREFIX_MOUNT}"
SB_OWNER="${SB_OWNER}"
EOF
    run "$SB_SUDO" install -o "$o" -g "$g" -m 644 "$tmp_conf" "${SB_TOOLS_DIR}/synobrew.conf"
    rm -f "$tmp_conf"
  fi
  print_boot_task_instructions "${SB_TOOLS_DIR}/restore.sh"
}

print_boot_task_instructions() {
  # Canonicalize the dir when it exists (resolves the DSM homes symlink to its
  # /volumeX/... path for the boot task); fall back to the literal dir when it
  # doesn't exist yet — e.g. under --dry-run, where `run mkdir` was a no-op and
  # an unguarded `cd`+`pwd` would collapse the path to a broken "/restore.sh".
  local dir base canon restore_abs
  dir="$(dirname "$1")"; base="$(basename "$1")"
  canon="$(cd "$dir" 2>/dev/null && pwd)" || true
  restore_abs="${canon:-$dir}/$base"
  cat >&2 <<EOF
synobrew: ---------------------------------------------------------------
synobrew: ONE MANUAL STEP — make the mount survive reboots:
synobrew:   DSM > Control Panel > Task Scheduler > Create > Triggered Task
synobrew:   > User-defined script.  User: root.  Event: Boot-up.
synobrew:   Run command:  ${restore_abs}
synobrew: ---------------------------------------------------------------
EOF
}

maybe_install_brew() {
  if [ -x "${SB_PREFIX_MOUNT}/.linuxbrew/bin/brew" ]; then
    log "Homebrew already present; skipping installer."
    return
  fi
  if $DRY_RUN; then log "[dry-run] run official Homebrew installer from $SB_BREW_INSTALL_URL"; return; fi
  log "running official Homebrew installer..."
  # Fetch into a variable so a failed download aborts. A bare
  # `bash -c "$(curl ...)"` swallows curl's failure: on error curl prints
  # nothing, `bash -c ""` exits 0, and the install would falsely "succeed".
  local installer
  installer="$("$SB_CURL" -fsSL "$SB_BREW_INSTALL_URL")" || die "failed to fetch the Homebrew installer from $SB_BREW_INSTALL_URL"
  [ -n "$installer" ] || die "the Homebrew installer fetched from $SB_BREW_INSTALL_URL was empty"
  if $ASSUME_YES; then
    NONINTERACTIVE=1 /bin/bash -c "$installer"
  else
    /bin/bash -c "$installer"
  fi
}

sudo_keepalive() {
  $DRY_RUN && return 0
  "$SB_SUDO" -v || die "sudo authentication required (be an administrators-group user)."
  # Fully detach the keep-alive's descriptors: stdin/stdout/stderr to /dev/null
  # and close any inherited fd 3. The EXIT-trap kill reaps the subshell but not
  # its in-flight `sleep`, so an undetached sleep would keep a caller's pipe
  # open until it wakes — a pipe-capturing harness (e.g. bats, which uses fd 3)
  # then blocks ~50s at exit. Detaching lets the caller see EOF immediately.
  ( while true; do sleep "$SB_KEEPALIVE_INTERVAL"; "$SB_SUDO" -n true 2>/dev/null || exit; done ) </dev/null >/dev/null 2>&1 3>&- &
  SB_KEEPALIVE_PID=$!
  trap 'kill "$SB_KEEPALIVE_PID" 2>/dev/null || true' EXIT
}

_append_once() {
  # $1 rc file, $2 exact line. Appends once (idempotent, guarded by grep -qxF).
  local rc="$1" line="$2"
  if [ -f "$rc" ] && grep -qxF "$line" "$rc"; then
    log "already present in $rc: $line"
    return
  fi
  if $DRY_RUN; then log "[dry-run] append to $rc: $line"; return; fi
  printf '\n# synobrew\n%s\n' "$line" >> "$rc"
  log "added to $rc: $line"
}

persist_shellenv() {
  local shell rc line temp_line brew_bin="${SB_PREFIX_MOUNT}/.linuxbrew/bin/brew"
  shell="$(sb_shell_from_path "${SHELL:-/bin/sh}")"
  rc="$(sb_rc_file "$shell" "$SB_HOME")"
  line="$(sb_shellenv_line "$shell" "$brew_bin")"
  if [ "$shell" = fish ]; then
    temp_line="set -gx HOMEBREW_TEMP \"$SB_HOME/tmp\""
  else
    temp_line="export HOMEBREW_TEMP=\"$SB_HOME/tmp\""
  fi
  # HOMEBREW_TEMP keeps Homebrew's large temp writes off DSM's ~2.4 GB system partition.
  run mkdir -p "$(dirname "$rc")" "$SB_HOME/tmp"
  _append_once "$rc" "$line"
  _append_once "$rc" "$temp_line"
  log "shell env persisted in $rc (open a new shell or source it)."
}

verify_and_summary() {
  local brew_bin="${SB_PREFIX_MOUNT}/.linuxbrew/bin/brew"
  if ! $DRY_RUN && [ -x "$brew_bin" ]; then
    "$brew_bin" --version || true
    "$brew_bin" config || true
    "$brew_bin" doctor || true
  fi
  log "done. Remember: after a DSM *update*, re-run this installer (it is idempotent)."
}

main() {
  parse_args "$@"
  preflight
  log "preflight passed."
  local state; state="$(detect_state)"
  log "state: $state"

  case "$state" in
    foreign-prefix)
      warn "an existing Homebrew was found at a non-standard prefix. It is NOT safe to relocate (bottles are path-specific)."
      confirm "install a fresh Homebrew at the standard prefix alongside it?" || die "aborted by user."
      ;;
    *)
      confirm "proceed with synobrew ($state) — will change /usr/bin/ldd, /etc/os-release, ${SB_PREFIX_MOUNT}, and your shell rc?" \
        || die "aborted by user."
      ;;
  esac

  sudo_keepalive
  [ "$state" = "foreign-backing" ] && migrate_prefix
  apply_shims
  install_persistence
  maybe_install_brew
  persist_shellenv
  verify_and_summary
}

main "$@"
