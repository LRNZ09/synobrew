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
