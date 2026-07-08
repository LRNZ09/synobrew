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
SB_LDD="${SB_LDD:-/usr/bin/ldd}"
SB_OSRELEASE="${SB_OSRELEASE:-/etc/os-release}"
SB_DSM_VERSION_FILE="${SB_DSM_VERSION_FILE:-/etc.defaults/VERSION}"
SB_LIBC="${SB_LIBC:-/usr/lib/libc.so.6}"
SB_HOMES_DIR="${SB_HOMES_DIR:-/var/services/homes}"
SB_MOUNT="${SB_MOUNT:-mount}"
SB_PROC_MOUNTS="${SB_PROC_MOUNTS:-/proc/mounts}"   # injectable; migrate reads it to detect a foreign mount at the prefix (DSM has no `mountpoint`)
SB_PGREP="${SB_PGREP:-pgrep}"                  # injectable; guarded (may be absent on DSM's base userland)
SB_SUDO="${SB_SUDO:-sudo}"
SB_UNAME_M="${SB_UNAME_M:-$(uname -m)}"
SB_GIT="${SB_GIT:-git}"
# Command name of the parent process (the interactive shell that launched us). On
# DSM $SHELL is the passwd login shell (often /bin/sh) even when the user runs
# fish, so persist_shellenv also consults this to target the right rc file. Reads
# /proc first (reliable on DSM's busybox userland), falls back to ps; injectable.
SB_PARENT_COMM="${SB_PARENT_COMM:-$( { cat "/proc/${PPID:-0}/comm" 2>/dev/null || ps -o comm= -p "${PPID:-0}" 2>/dev/null; } | tr -d '[:space:]' || true)}"
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

  if [ ! -d "$SB_HOME" ]; then
    die "your home directory is missing ($SB_HOME). Enable Control Panel > User & Group > Advanced > User Home (homes live under $SB_HOMES_DIR), then re-run."
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
  local brew_std=0 same=0 elsewhere=0
  [ -x "${SB_PREFIX_MOUNT}/.linuxbrew/bin/brew" ] && brew_std=1
  # "Managed" == our store is currently bind-mounted at the prefix. dev:inode
  # equality of the two paths is the ground truth (a bind mount makes them the
  # same directory) and works for bind mounts even on DSM's busybox userland,
  # which may not provide a working `mountpoint` — the old mountpoint-based check
  # reported "not mounted" on DSM and re-triggered migration on every re-run.
  local mount_di store_di
  mount_di="$(sb_dev_inode "$SB_PREFIX_MOUNT")"
  store_di="$(sb_dev_inode "$SB_PREFIX_STORE")"
  if [ -n "$mount_di" ] && [ "$mount_di" = "$store_di" ]; then same=1; fi
  # Foreign-prefix probe uses the injectable SB_BREW (not a bare `command -v
  # brew`) so tests can neutralize it (SB_BREW=$SANDBOX/no-such-brew); hosts
  # that already have Homebrew on PATH would otherwise flip fresh -> foreign-prefix.
  if [ "$brew_std" = 0 ] && command -v "$SB_BREW" >/dev/null 2>&1; then elsewhere=1; fi
  sb_classify_state "$brew_std" "$same" "$elsewhere"
}

SB_OWNER="${SB_OWNER:-$(id -un):$(id -gn)}"
SB_EPOCH="${SB_EPOCH:-$(date +%s)}"
# Sudo keep-alive refresh cadence (seconds). Injectable so tests can shrink it:
# the keep-alive's `sleep` is orphaned when we kill the subshell at exit, and a
# pipe-capturing harness (bats) waits on it — a low value keeps the suite fast.
SB_KEEPALIVE_INTERVAL="${SB_KEEPALIVE_INTERVAL:-50}"

backup_if_present() {
  # Back up a genuine PRE-EXISTING (non-synobrew) file exactly once, before we
  # first overwrite it. Skip our own shim/file, and skip if we already backed it
  # up on an earlier run — so idempotent re-runs don't accumulate junk backups.
  [ -e "$1" ] || return 0
  if { "$1" --version 2>/dev/null || cat "$1" 2>/dev/null; } | grep -q synobrew; then
    log "already synobrew's own $1; not backing up"; return 0
  fi
  local existing
  for existing in "$1".synobrew.bak-*; do
    [ -e "$existing" ] && { log "backup already exists for $1; skipping"; return 0; }
  done
  local bak; bak="$(sb_bak_name "$1" "$SB_EPOCH")"
  # Copy via sudo: the target may be a root-owned system file (/etc/os-release,
  # /usr/bin/ldd), so a non-root cp would EACCES and abort under set -e. sudo is
  # already primed by sudo_keepalive (runs before apply_shims).
  run "$SB_SUDO" cp -a "$1" "$bak"
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
  if command -v "$SB_PGREP" >/dev/null 2>&1; then
    "$SB_PGREP" -x brew >/dev/null 2>&1 && die "a 'brew' process is running; stop it and retry."
  else
    warn "cannot check for a running brew ($SB_PGREP unavailable); ensure no 'brew' process is active before continuing."
  fi
  # In the foreign-backing state the prefix is NOT our store, so any filesystem
  # currently mounted at the prefix is foreign — an old whole-homes bind, a prior
  # synobrew mount at a different store, etc. Auto-unmounting an unknown mount is
  # unsafe (it could drop a live share), so refuse with instructions instead of
  # guessing. Detected via /proc/mounts because DSM's busybox ships no `mountpoint`
  # (and dev:inode can't tell "is a mount" for a bind on the same fs). Checked
  # BEFORE copying anything. NOTE: a mounted PARENT (e.g. /home) is normal on DSM
  # and is deliberately NOT treated as an error — only a mount at the prefix is.
  if sb_is_mounted "$mnt" "$SB_PROC_MOUNTS"; then
    die "a foreign filesystem is mounted at ${mnt}; synobrew will not unmount an unknown mount for you. Unmount it manually (sudo umount ${mnt}; your data stays at its source) and re-run."
  fi
  [ ! -e "${store}/.linuxbrew" ] || die "target store ${store}/.linuxbrew already exists; move it aside and retry (never clobbered)."
  log "migrating existing prefix into ${store} (a DSM snapshot first is recommended)."
  run mkdir -p "${store}/.linuxbrew"
  # -aH (not -aHAX): a Linuxbrew prefix needs ownership/mode/hardlinks preserved,
  # not POSIX ACLs/xattrs — and DSM's stock rsync may lack -A/-X support.
  run "$SB_RSYNC" -aH --numeric-ids "${mnt}/.linuxbrew/" "${store}/.linuxbrew/"
  if ! $DRY_RUN; then
    [ -x "${store}/.linuxbrew/bin/brew" ] || die "migration copy failed: no brew at ${store}/.linuxbrew/bin/brew"
  fi
  # The prefix is a plain directory (we refused above if it were a mount), so move
  # the old prefix aside; it stays HIDDEN beneath the bind mount restore.sh adds.
  if [ -d "${mnt}/.linuxbrew" ]; then
    run mv "${mnt}/.linuxbrew" "${mnt}/.linuxbrew.synobrew-old-${SB_EPOCH}"
    log "old prefix moved to ${mnt}/.linuxbrew.synobrew-old-${SB_EPOCH}; it will be HIDDEN beneath the new bind mount. To remove it later: sudo umount ${mnt} && sudo rm -rf ${mnt}/.linuxbrew.synobrew-old-${SB_EPOCH} (then reboot or re-run restore.sh)."
  fi
}

install_persistence() {
  # Reboot persistence is a self-contained INLINE mount command registered in the
  # DSM Task Scheduler (whose config is root-only) — NOT a script installed under
  # the user's home. This removes the "root runs a user-controllable file at boot"
  # attack surface entirely: root only runs a fixed command that bind-mounts the
  # user-owned prefix store (data, never executed). The ldd/os-release shims are
  # applied at install time (apply_shims) and survive plain reboots; a DSM *update*
  # that wipes them is recovered by re-running this installer.
  # pwd -P resolves the DSM homes symlink (/var/services/homes -> /volume1/homes)
  # so the baked path is stable at boot when root has no $HOME; fall back to the
  # literal path when the store doesn't exist yet (e.g. --dry-run).
  local abs_store; abs_store="$(cd "$SB_PREFIX_STORE" 2>/dev/null && pwd -P || echo "$SB_PREFIX_STORE")"
  print_boot_task_instructions "$abs_store"
}

print_boot_task_instructions() {
  # $1: physical absolute prefix-store path to bind-mount at boot.
  cat >&2 <<EOF
synobrew: ---------------------------------------------------------------
synobrew: ONE MANUAL STEP — make the mount survive reboots:
synobrew:   DSM > Control Panel > Task Scheduler > Create > Triggered Task
synobrew:   > User-defined script.  User: root.  Event: Boot-up.
synobrew:   Run command (paste exactly):
synobrew:     mkdir -p ${SB_PREFIX_MOUNT} && mount -o bind '${1}' ${SB_PREFIX_MOUNT}
synobrew: ---------------------------------------------------------------
synobrew: (The command lives in DSM's root-only config — no script under your home
synobrew:  runs as root. After a DSM *update*, re-run this installer to restore the shims.)
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
  local brew_bin="${SB_PREFIX_MOUNT}/.linuxbrew/bin/brew"

  # Homebrew resets its own PATH to /usr/bin:/bin:/usr/sbin:/sbin — dropping
  # /usr/local/bin, where DSM/SynoCommunity keeps git — so it cannot see a system
  # git that install.sh itself found. HOMEBREW_GIT_PATH survives brew's env filter
  # and is consumed without a PATH lookup, so set it when the system git meets
  # Homebrew's 2.7.0 floor; otherwise point the user at `brew install git`.
  local git_path git_ver set_git_path=false
  git_path="$(command -v "$SB_GIT" 2>/dev/null || true)"
  if [ -n "$git_path" ]; then
    git_ver="$("$SB_GIT" --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+' | head -n1 || true)"
    if [ -n "$git_ver" ] && sb_version_ge "$git_ver" "2.7"; then
      set_git_path=true
    else
      warn "system git ($git_path) is older than Homebrew's 2.7.0 minimum; run 'brew install git' after setup."
    fi
  else
    warn "no system git found; run 'brew install git' after setup (Homebrew needs git >= 2.7.0)."
  fi

  # Which shells to configure: the login shell ($SHELL) PLUS the interactive shell
  # (on DSM $SHELL is the passwd shell — often /bin/sh — even when the user runs
  # fish on top), detected from the parent process and any existing fish config
  # dir. Writing to each means brew loads whichever shell the user actually opens.
  local login_shell interactive_shell
  login_shell="$(sb_shell_from_path "${SHELL:-/bin/sh}")"
  interactive_shell="$(sb_shell_from_path "${SB_PARENT_COMM#-}")"
  local -a shells=("$login_shell")
  if [ "$interactive_shell" != other ] && [ "$interactive_shell" != "$login_shell" ]; then
    shells+=("$interactive_shell")
  fi
  if [ -d "$SB_HOME/.config/fish" ]; then
    case " ${shells[*]} " in *" fish "*) ;; *) shells+=(fish) ;; esac
  fi

  run mkdir -p "$SB_HOME/tmp"
  local sh rc written=""
  for sh in "${shells[@]}"; do
    rc="$(sb_rc_file "$sh" "$SB_HOME")"
    run mkdir -p "$(dirname "$rc")"
    _append_once "$rc" "$(sb_shellenv_line "$sh" "$brew_bin")"
    # HOMEBREW_TEMP keeps Homebrew's large temp writes off DSM's ~2.4 GB system partition.
    _append_once "$rc" "$(sb_env_line "$sh" HOMEBREW_TEMP "$SB_HOME/tmp")"
    # DSM kernels cannot do rootless sandboxing (unprivileged user namespaces are
    # disabled), so disable it to silence the per-build warning. See README.
    _append_once "$rc" "$(sb_env_line "$sh" HOMEBREW_NO_SANDBOX_LINUX 1)"
    if $set_git_path; then
      _append_once "$rc" "$(sb_env_line "$sh" HOMEBREW_GIT_PATH "$git_path")"
    fi
    written="$written $rc"
  done
  log "shell env persisted in:${written} (open a new shell or source it)."
  log "configured shell(s): ${shells[*]} — if you use a different shell, add the printed lines to its rc."
}

verify_and_summary() {
  local brew_bin="${SB_PREFIX_MOUNT}/.linuxbrew/bin/brew"
  if ! $DRY_RUN && [ -x "$brew_bin" ]; then
    "$brew_bin" --version 2>/dev/null | head -n1 || true
  fi
  log "Homebrew is installed at ${SB_PREFIX_MOUNT}/.linuxbrew."
  # Deliberately NOT running `brew doctor` here: at install time the shellenv is
  # written but not yet sourced, so doctor emits PATH/"bin not found" warnings that
  # vanish in a fresh shell; and on DSM it always reports the Tier-2 (old glibc) and
  # rootless-Bubblewrap-sandbox notes. Framing those as expected beats ending on a
  # wall of alarming-but-benign red.
  cat >&2 <<EOF
synobrew: ---------------------------------------------------------------
synobrew: NEXT: open a new shell (or source your rc) so 'brew' is on PATH.
synobrew: These are EXPECTED on Synology — not errors:
synobrew:   - "Tier 2" / "glibc too old": Homebrew installs its own glibc (a bottle). Normal on DSM.
synobrew:   - "Bubblewrap cannot create a rootless sandbox": DSM kernels can't; we set
synobrew:     HOMEBREW_NO_SANDBOX_LINUX=1 to quiet it. Ignore brew's sysctl advice (Debian/Ubuntu-only).
synobrew:   - PATH / "bin not found" warnings: clear once a new shell sources your rc.
synobrew: For a real health check, run 'brew doctor' yourself in a fresh shell.
synobrew: ---------------------------------------------------------------
EOF
  if [ "$(sb_classify_arch "$SB_UNAME_M")" = warn ]; then
    log "on $SB_UNAME_M many formulae build from source — run 'brew install gcc' first so builds have a compiler."
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
    foreign-backing)
      warn "an existing Homebrew prefix will be RELOCATED: its contents under ${SB_PREFIX_MOUNT}/.linuxbrew are copied into ${SB_PREFIX_STORE} (the logical path is unchanged). A DSM snapshot first is recommended."
      confirm "proceed — move the prefix data to ${SB_PREFIX_STORE} and change /usr/bin/ldd, /etc/os-release, ${SB_PREFIX_MOUNT}, and your shell rc?" \
        || die "aborted by user."
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
