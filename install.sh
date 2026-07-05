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

main() {
  parse_args "$@"
  preflight
  log "preflight passed."
}

main "$@"
