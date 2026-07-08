#!/usr/bin/env bats

setup() {
  SB_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SANDBOX="$(mktemp -d)"
  mkdir -p "$SANDBOX/etc.defaults" "$SANDBOX/home"
  printf 'majorversion="7"\nminorversion="2"\nproductversion="7.2.1"\n' > "$SANDBOX/etc.defaults/VERSION"
  # Common env for a healthy x86_64 DSM 7.2 sandbox, non-root.
  export SB_HOME="$SANDBOX/home"
  export SB_DSM_VERSION_FILE="$SANDBOX/etc.defaults/VERSION"
  export SB_HOMES_DIR="$SANDBOX/home"
  export SB_UNAME_M="x86_64"
  export SB_EUID="1000"
  export SB_LIBC="/no/libc"
  export SB_PREFIX_MOUNT="$SANDBOX/home_linuxbrew"
  export SB_PREFIX_STORE="$SANDBOX/store"
  export SB_BREW="$SANDBOX/no-such-brew"
  export SB_KEEPALIVE_INTERVAL=1   # keep the sudo keep-alive's orphaned sleep short so bats doesn't block on it
  # Pin shell + git detection so persist_shellenv is hermetic (never reads the host's
  # $SHELL, parent process, or git).
  export SHELL="/bin/bash"
  export SB_PARENT_COMM="bash"
  printf '#!/bin/sh\necho "git version 2.40.1"\n' > "$SANDBOX/git-stub"
  chmod +x "$SANDBOX/git-stub"; export SB_GIT="$SANDBOX/git-stub"
}

teardown() { rm -rf "$SANDBOX"; }

@test "install.sh --help exits 0 and prints usage" {
  run bash "$SB_ROOT/install.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: install.sh"* ]]
}

@test "install.sh rejects unknown arg" {
  run bash "$SB_ROOT/install.sh" --bogus
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown argument"* ]]
}

@test "preflight aborts as root" {
  SB_EUID=0 run bash "$SB_ROOT/install.sh" --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"do not run as root"* ]]
}

@test "preflight blocks 32-bit arch" {
  SB_UNAME_M=armv7l run bash "$SB_ROOT/install.sh" --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"not supported"* ]]
}

@test "preflight blocks old DSM" {
  printf 'majorversion="6"\nminorversion="2"\nproductversion="6.2"\n' > "$SANDBOX/etc.defaults/VERSION"
  run bash "$SB_ROOT/install.sh" --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"too old"* ]]
}

@test "preflight passes on healthy x86_64 DSM 7.2 (dry-run)" {
  run bash "$SB_ROOT/install.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"preflight passed"* ]]
}

@test "preflight warns on aarch64 but proceeds" {
  SB_UNAME_M=aarch64 run bash "$SB_ROOT/install.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"build from source"* ]]
}

@test "preflight logs glibc when libc reports a version (informational, non-fatal)" {
  printf '#!/bin/sh\necho "GNU C Library (GNU libc) stable release version 2.36."\n' > "$SANDBOX/libc"
  chmod +x "$SANDBOX/libc"
  SB_LIBC="$SANDBOX/libc" run bash "$SB_ROOT/install.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"glibc detected: 2.36"* ]]
  [[ "$output" == *"preflight passed"* ]]
}

@test "preflight does not abort when libc reports no version (set -e safe)" {
  printf '#!/bin/sh\necho "no version token here"\n' > "$SANDBOX/libc"
  chmod +x "$SANDBOX/libc"
  SB_LIBC="$SANDBOX/libc" run bash "$SB_ROOT/install.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"glibc detected"* ]]
  [[ "$output" == *"preflight passed"* ]]
}

@test "detect_state: fresh when nothing present" {
  run bash "$SB_ROOT/install.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"state: fresh"* ]]
}

@test "detect_state: managed when the store is mounted at the prefix (dev:inode match, no mountpoint)" {
  # Regression: a re-run of a synobrew-managed install must be detected as 'managed',
  # NOT re-migrated. A live bind mount makes the prefix and the store the same
  # directory (identical dev:inode); model that with a single shared path — a real
  # bind mount needs root and isn't available in CI, and a symlink isn't portable
  # (BSD stat doesn't follow a final-component symlink). This exercises the dev:inode
  # check that replaced the DSM-unreliable `mountpoint` probe.
  mkdir -p "$SANDBOX/managed/.linuxbrew/bin"
  printf '#!/bin/sh\necho brew\n' > "$SANDBOX/managed/.linuxbrew/bin/brew"
  chmod +x "$SANDBOX/managed/.linuxbrew/bin/brew"
  export SB_PREFIX_MOUNT="$SANDBOX/managed"
  export SB_PREFIX_STORE="$SANDBOX/managed"
  run bash "$SB_ROOT/install.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"state: managed"* ]]
  [[ "$output" != *"RELOCATED"* ]]   # must NOT attempt migration
}

@test "detect_state: foreign-backing when a real (unmounted) prefix exists" {
  export SB_PREFIX_MOUNT="$SANDBOX/home_linuxbrew"
  export SB_PREFIX_STORE="$SANDBOX/store"
  mkdir -p "$SB_PREFIX_MOUNT/.linuxbrew/bin"
  cat > "$SB_PREFIX_MOUNT/.linuxbrew/bin/brew" <<'SH'
#!/bin/sh
echo "Homebrew 4.x"
SH
  chmod +x "$SB_PREFIX_MOUNT/.linuxbrew/bin/brew"
  run bash "$SB_ROOT/install.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"state: foreign-backing"* ]]
}

# Helper: a full hermetic sandbox — sudo is a no-op passthrough, mount/rsync/curl
# are stubs, and Homebrew's installer is a local stub script (no network, no
# real /home/linuxbrew, no real brew).
_full_sandbox_env() {
  export SB_PREFIX_MOUNT="$SANDBOX/home_linuxbrew"
  export SB_PREFIX_STORE="$SANDBOX/store"
  export SB_LDD="$SANDBOX/ldd"
  export SB_OSRELEASE="$SANDBOX/os-release"
  export SB_LIBC="/no/libc"
  export SB_BREW="$SANDBOX/no-such-brew"      # nothing "elsewhere" unless a test sets it
  # SHELL / SB_PARENT_COMM / SB_GIT (a new-enough git stub) are pinned in setup().
  # Tests override SB_GIT for old/absent-git cases.

  # no-op sudo passthrough: drop -v/-k, strip -n, exec the rest (incl. `env`)
  cat > "$SANDBOX/sudo" <<'SH'
#!/bin/sh
case "$1" in -v|-k) exit 0 ;; -n) shift ;; esac
exec "$@"
SH
  chmod +x "$SANDBOX/sudo"; export SB_SUDO="$SANDBOX/sudo"

  # mount stub: records args AND emulates the bind by mirroring SRC into DST,
  # so code that reads the "mounted" prefix (maybe_install_brew) sees it.
  # restore.sh calls: mount -o bind SRC DST
  cat > "$SANDBOX/mount-stub" <<'SH'
#!/bin/sh
echo "MOUNT $*" >> "$MOUNT_LOG"
if [ "$1" = "-o" ] && [ "$2" = "bind" ] && [ -d "$3" ]; then
  mkdir -p "$4"
  cp -R "$3/." "$4/" 2>/dev/null || true
fi
SH
  chmod +x "$SANDBOX/mount-stub"
  export MOUNT_LOG="$SANDBOX/mount.log"; export SB_MOUNT="$SANDBOX/mount-stub"

  # rsync stub: portable copy (macOS openrsync rejects -aHAX). Last two
  # non-flag args are SRC/ and DST/ (rsync's own convention: source then dest).
  cat > "$SANDBOX/rsync-stub" <<'SH'
#!/bin/sh
src=""; dst=""
for a in "$@"; do
  case "$a" in
    -*) continue ;;
  esac
  src="$dst"
  dst="$a"
done
mkdir -p "$dst"
cp -R "${src}." "$dst" 2>/dev/null || true
SH
  chmod +x "$SANDBOX/rsync-stub"; export SB_RSYNC="$SANDBOX/rsync-stub"

  # installer stub: fetched via SB_CURL, run by /bin/bash -c; creates brew AT THE MOUNT.
  cat > "$SANDBOX/brew-install.sh" <<SH
#!/bin/sh
mkdir -p "$SB_PREFIX_MOUNT/.linuxbrew/bin"
cat > "$SB_PREFIX_MOUNT/.linuxbrew/bin/brew" <<'BREW'
#!/bin/sh
echo "Homebrew (synobrew test stub) 4.x"
BREW
chmod +x "$SB_PREFIX_MOUNT/.linuxbrew/bin/brew"
SH
  chmod +x "$SANDBOX/brew-install.sh"
  export SB_BREW_INSTALL_URL="$SANDBOX/brew-install.sh"

  # SB_CURL stub: ignore flags, cat the local "URL" (the installer path) to stdout.
  cat > "$SANDBOX/curl-stub" <<'SH'
#!/bin/sh
for last in "$@"; do :; done          # last arg = the URL == local installer path
cat "$last"
SH
  chmod +x "$SANDBOX/curl-stub"; export SB_CURL="$SANDBOX/curl-stub"

  # pgrep stub: report no running 'brew' (deterministic; never read the host's
  # process table, which would make the migrate tests host-dependent).
  printf '#!/bin/sh\nexit 1\n' > "$SANDBOX/pgrep-none"; chmod +x "$SANDBOX/pgrep-none"
  export SB_PGREP="$SANDBOX/pgrep-none"

  # Empty /proc/mounts by default: nothing is mounted, so migrate never refuses.
  # The "foreign mount at the prefix" test overrides this with a populated file.
  : > "$SANDBOX/proc-mounts"; export SB_PROC_MOUNTS="$SANDBOX/proc-mounts"
}

@test "fresh install (dry-run) reports all planned actions" {
  _full_sandbox_env
  run bash "$SB_ROOT/install.sh" --dry-run --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"state: fresh"* ]]
  [[ "$output" == *"[dry-run]"* ]]
  [[ "$output" == *"Task Scheduler"* ]]
  [[ "$output" == *"official Homebrew installer"* ]]
  # Boot task is an inline mount command (no installed script). Under --dry-run
  # the store dir is absent, so the path falls back to the literal store.
  [[ "$output" == *"mount -o bind '$SB_PREFIX_STORE' $SB_PREFIX_MOUNT"* ]]
}

@test "fresh install (real, sandboxed) installs via the stub + writes persistence + shellenv" {
  _full_sandbox_env
  run bash "$SB_ROOT/install.sh" --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"state: fresh"* ]]
  [ -x "$SB_PREFIX_MOUNT/.linuxbrew/bin/brew" ]
  [[ "$output" == *"mount -o bind"* ]]      # inline boot task printed (no installed script)
  [[ "$output" == *"$SB_PREFIX_MOUNT"* ]]
  [ -d "$SB_PREFIX_STORE" ]                  # store created (and chowned user-owned)
  grep -q 'brew shellenv' "$SB_HOME/.profile"
  grep -q 'HOMEBREW_TEMP' "$SB_HOME/.profile"
}

@test "fresh install aborts (no silent success) if the Homebrew installer fetch fails" {
  _full_sandbox_env
  printf '#!/bin/sh\nexit 22\n' > "$SANDBOX/curl-fail"; chmod +x "$SANDBOX/curl-fail"
  export SB_CURL="$SANDBOX/curl-fail"
  run bash "$SB_ROOT/install.sh" --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"failed to fetch"* ]]
  [ ! -x "$SB_PREFIX_MOUNT/.linuxbrew/bin/brew" ]   # no phantom brew
  [[ "$output" != *"done."* ]]                       # never reports success
}

@test "apply_shims backs up a pre-existing non-synobrew ldd/os-release exactly once" {
  _full_sandbox_env
  printf 'REAL-OSRELEASE-SENTINEL\n' > "$SB_OSRELEASE"
  printf '#!/bin/sh\necho "ldd (GNU libc) 2.31"\n' > "$SB_LDD"; chmod +x "$SB_LDD"
  run bash "$SB_ROOT/install.sh" --yes
  [ "$status" -eq 0 ]
  osbak=$(compgen -G "$SB_OSRELEASE.synobrew.bak-*") || true
  [ -n "$osbak" ]                                                       # a backup was made
  [ "$(compgen -G "$SB_OSRELEASE.synobrew.bak-*" | wc -l | tr -d ' ')" -eq 1 ]
  grep -q REAL-OSRELEASE-SENTINEL "$osbak"                              # it holds the ORIGINAL content
  lddbak=$(compgen -G "$SB_LDD.synobrew.bak-*") || true
  [ -n "$lddbak" ]; grep -q 'GNU libc' "$lddbak"
  # second run: the files are now synobrew's own -> no additional backup piles up
  run bash "$SB_ROOT/install.sh" --yes
  [ "$status" -eq 0 ]
  [ "$(compgen -G "$SB_OSRELEASE.synobrew.bak-*" | wc -l | tr -d ' ')" -eq 1 ]
}

@test "shellenv is idempotent across two runs" {
  _full_sandbox_env
  run bash "$SB_ROOT/install.sh" --yes
  [ "$status" -eq 0 ]
  run bash "$SB_ROOT/install.sh" --yes
  [ "$status" -eq 0 ]
  [ "$(grep -c 'brew shellenv' "$SB_HOME/.profile")" -eq 1 ]
}

@test "migrate copies an existing prefix into the new store" {
  _full_sandbox_env
  # Existing (unmounted, real-dir) prefix at the mount path -> foreign-backing.
  mkdir -p "$SB_PREFIX_MOUNT/.linuxbrew/bin"
  printf '#!/bin/sh\necho brew\n' > "$SB_PREFIX_MOUNT/.linuxbrew/bin/brew"
  chmod +x "$SB_PREFIX_MOUNT/.linuxbrew/bin/brew"
  echo "payload" > "$SB_PREFIX_MOUNT/.linuxbrew/marker.txt"
  run bash "$SB_ROOT/install.sh" --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"state: foreign-backing"* ]]
  [[ "$output" == *"RELOCATED"* ]]   # the confirm discloses the prefix data move (spec §4.4)
  [ -x "$SB_PREFIX_STORE/.linuxbrew/bin/brew" ]
  grep -q payload "$SB_PREFIX_STORE/.linuxbrew/marker.txt"
  compgen -G "$SB_PREFIX_MOUNT/.linuxbrew.synobrew-old-*" > /dev/null
}

@test "migrate refuses to clobber a non-empty target store" {
  _full_sandbox_env
  mkdir -p "$SB_PREFIX_MOUNT/.linuxbrew/bin" "$SB_PREFIX_STORE/.linuxbrew"
  printf '#!/bin/sh\necho brew\n' > "$SB_PREFIX_MOUNT/.linuxbrew/bin/brew"
  chmod +x "$SB_PREFIX_MOUNT/.linuxbrew/bin/brew"
  run bash "$SB_ROOT/install.sh" --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"already exists"* ]]
}

@test "migrate refuses (before copying) when a foreign filesystem is mounted at the prefix" {
  _full_sandbox_env
  # brew at the sandbox prefix -> foreign-backing; a /proc/mounts that lists the
  # prefix itself as an active (foreign) mount must make synobrew refuse rather
  # than auto-unmount an unknown mount.
  mkdir -p "$SB_PREFIX_MOUNT/.linuxbrew/bin"
  printf '#!/bin/sh\necho brew\n' > "$SB_PREFIX_MOUNT/.linuxbrew/bin/brew"
  chmod +x "$SB_PREFIX_MOUNT/.linuxbrew/bin/brew"
  printf 'somedev %s ext4 rw 0 0\n' "$SB_PREFIX_MOUNT" > "$SANDBOX/proc-mounts"
  run bash "$SB_ROOT/install.sh" --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"foreign filesystem is mounted at"* ]]
  [ ! -e "$SB_PREFIX_STORE/.linuxbrew" ]   # refused before any copy
}

@test "migrate proceeds when the PARENT is mounted but the prefix itself is not (normal DSM)" {
  _full_sandbox_env
  # Regression for the DSM reality: /home is itself a mount. A mounted parent must
  # NOT be treated as the old 'whole homes share' error — only a mount at the
  # prefix is. Here only dirname(prefix) is listed in /proc/mounts.
  mkdir -p "$SB_PREFIX_MOUNT/.linuxbrew/bin"
  printf '#!/bin/sh\necho brew\n' > "$SB_PREFIX_MOUNT/.linuxbrew/bin/brew"
  chmod +x "$SB_PREFIX_MOUNT/.linuxbrew/bin/brew"
  printf 'vol %s ext4 rw 0 0\n' "$(dirname "$SB_PREFIX_MOUNT")" > "$SANDBOX/proc-mounts"
  run bash "$SB_ROOT/install.sh" --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"state: foreign-backing"* ]]
  [ -x "$SB_PREFIX_STORE/.linuxbrew/bin/brew" ]   # migration proceeded, not refused
}

@test "persist_shellenv sets HOMEBREW_GIT_PATH when the system git is new enough" {
  _full_sandbox_env
  run bash "$SB_ROOT/install.sh" --yes
  [ "$status" -eq 0 ]
  grep -q "HOMEBREW_GIT_PATH=\"$SANDBOX/git-stub\"" "$SB_HOME/.profile"
}

@test "persist_shellenv warns and omits HOMEBREW_GIT_PATH when git is too old" {
  _full_sandbox_env
  printf '#!/bin/sh\necho "git version 2.6.0"\n' > "$SANDBOX/git-old"; chmod +x "$SANDBOX/git-old"
  export SB_GIT="$SANDBOX/git-old"
  run bash "$SB_ROOT/install.sh" --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"older than Homebrew's 2.7.0"* ]]
  ! grep -q HOMEBREW_GIT_PATH "$SB_HOME/.profile"
}

@test "persist_shellenv warns and omits HOMEBREW_GIT_PATH when no system git is present" {
  _full_sandbox_env
  export SB_GIT="$SANDBOX/no-such-git"
  run bash "$SB_ROOT/install.sh" --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"no system git found"* ]]
  ! grep -q HOMEBREW_GIT_PATH "$SB_HOME/.profile"
}

@test "persist_shellenv makes HOMEBREW_TEMP sticky + not world-writable (brew doctor clean)" {
  _full_sandbox_env
  run bash "$SB_ROOT/install.sh" --yes
  [ "$status" -eq 0 ]
  [ -d "$SB_HOME/tmp" ]
  local perms; perms="$(stat -c '%A' "$SB_HOME/tmp" 2>/dev/null || stat -f '%Sp' "$SB_HOME/tmp")"
  [[ "$perms" == *t ]]              # sticky bit set (e.g. drwxr-xr-t)
  [ "${perms:8:1}" != "w" ]        # other-write bit off (not world-writable)
}

@test "persist_shellenv sets HOMEBREW_NO_SANDBOX_LINUX (DSM cannot rootless-sandbox)" {
  _full_sandbox_env
  run bash "$SB_ROOT/install.sh" --yes
  [ "$status" -eq 0 ]
  grep -q 'HOMEBREW_NO_SANDBOX_LINUX' "$SB_HOME/.profile"
}

@test "persist_shellenv wraps its lines in ONE removable # synobrew start/end block" {
  _full_sandbox_env
  run bash "$SB_ROOT/install.sh" --yes
  [ "$status" -eq 0 ]
  [ "$(grep -c '^# synobrew start$' "$SB_HOME/.profile")" -eq 1 ]
  [ "$(grep -c '^# synobrew end$' "$SB_HOME/.profile")" -eq 1 ]
  [ "$(grep -c '^# synobrew' "$SB_HOME/.profile")" -eq 2 ]   # only start + end, no per-line markers
}

@test "persist_shellenv preserves user rc content and collapses a legacy per-line entry into the block" {
  _full_sandbox_env
  # user content + an OLD-format synobrew entry (bare '# synobrew' + a managed line)
  printf 'export USER_THING=1\n# synobrew\nexport HOMEBREW_NO_SANDBOX_LINUX="1"\n' > "$SB_HOME/.profile"
  run bash "$SB_ROOT/install.sh" --yes
  [ "$status" -eq 0 ]
  grep -q '^export USER_THING=1$' "$SB_HOME/.profile"                     # user content kept
  [ "$(grep -c '^# synobrew start$' "$SB_HOME/.profile")" -eq 1 ]         # exactly one block
  [ "$(grep -c '^# synobrew$' "$SB_HOME/.profile")" -eq 0 ]               # legacy bare marker gone
  [ "$(grep -c 'HOMEBREW_NO_SANDBOX_LINUX' "$SB_HOME/.profile")" -eq 1 ]  # not duplicated
}

@test "persist_shellenv also configures fish when it is the interactive shell (not \$SHELL)" {
  _full_sandbox_env
  export SHELL="/bin/sh"        # DSM login shell...
  export SB_PARENT_COMM="fish"  # ...but the user runs fish on top
  run bash "$SB_ROOT/install.sh" --yes
  [ "$status" -eq 0 ]
  # POSIX rc still written for the login shell (covers exec-fish-from-.profile):
  grep -q 'brew shellenv' "$SB_HOME/.profile"
  # AND the fish rc is written with fish-form lines:
  grep -q 'shellenv fish | source' "$SB_HOME/.config/fish/conf.d/synobrew.fish"
  grep -q 'set -gx HOMEBREW_NO_SANDBOX_LINUX' "$SB_HOME/.config/fish/conf.d/synobrew.fish"
  grep -q "set -gx HOMEBREW_GIT_PATH \"$SANDBOX/git-stub\"" "$SB_HOME/.config/fish/conf.d/synobrew.fish"
}

@test "persist_shellenv detects fish from an existing ~/.config/fish dir" {
  _full_sandbox_env
  export SHELL="/bin/sh"
  export SB_PARENT_COMM="sh"        # parent is not fish...
  mkdir -p "$SB_HOME/.config/fish"  # ...but a fish config dir already exists
  run bash "$SB_ROOT/install.sh" --yes
  [ "$status" -eq 0 ]
  grep -q 'shellenv fish | source' "$SB_HOME/.config/fish/conf.d/synobrew.fish"
}

@test "verify_and_summary prints DSM expected-warnings guidance, not a raw brew doctor wall" {
  _full_sandbox_env
  run bash "$SB_ROOT/install.sh" --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"EXPECTED on Synology"* ]]
  [[ "$output" == *"HOMEBREW_NO_SANDBOX_LINUX=1"* ]]
  [[ "$output" == *"run 'brew doctor' yourself in a fresh shell"* ]]
}

@test "verify_and_summary suggests 'brew install gcc' on aarch64 (source builds)" {
  _full_sandbox_env
  export SB_UNAME_M="aarch64"
  run bash "$SB_ROOT/install.sh" --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"brew install gcc"* ]]
}

@test "verify_and_summary does NOT nag about gcc on x86_64" {
  _full_sandbox_env
  export SB_UNAME_M="x86_64"
  run bash "$SB_ROOT/install.sh" --yes
  [ "$status" -eq 0 ]
  [[ "$output" != *"brew install gcc"* ]]
}

@test "foreign-prefix: warns and never migrates when brew exists at a non-standard prefix" {
  _full_sandbox_env
  # A real brew resolves via SB_BREW, but none at our mount -> foreign-prefix.
  printf '#!/bin/sh\necho brew\n' > "$SANDBOX/realbrew"; chmod +x "$SANDBOX/realbrew"
  export SB_BREW="$SANDBOX/realbrew"
  run bash "$SB_ROOT/install.sh" --dry-run --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"state: foreign-prefix"* ]]
  [[ "$output" == *"NOT safe to relocate"* ]]
  [[ "$output" != *"migrating existing prefix"* ]]   # must NOT take the migrate path
}
