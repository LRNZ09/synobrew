#!/usr/bin/env bats

load test_helper

setup() {
  SB_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SANDBOX="$(mktemp -d)"
  # Fake DSM VERSION file and a fake libc that prints a glibc banner.
  mkdir -p "$SANDBOX/etc.defaults"
  printf 'productversion="7.2.1"\n' > "$SANDBOX/etc.defaults/VERSION"
  cat > "$SANDBOX/libc.so.6" <<'SH'
#!/bin/sh
echo "GNU C Library (GNU libc) stable release version 2.36."
SH
  chmod +x "$SANDBOX/libc.so.6"
  # A mount stub that just records its args (bind mount is impossible in CI).
  cat > "$SANDBOX/mount-stub" <<SH
#!/bin/sh
echo "MOUNT \$*" >> "$SANDBOX/mount.log"
SH
  chmod +x "$SANDBOX/mount-stub"
  export SB_PREFIX_MOUNT="$SANDBOX/home_linuxbrew"
  export SB_PREFIX_STORE="$SANDBOX/store"
  export SB_OWNER="$(id -un):$(id -gn)"
  export SB_LDD="$SANDBOX/ldd"
  export SB_OSRELEASE="$SANDBOX/os-release"
  export SB_LIBC="$SANDBOX/libc.so.6"
  export SB_DSM_VERSION_FILE="$SANDBOX/etc.defaults/VERSION"
  export SB_MOUNT="$SANDBOX/mount-stub"
}

teardown() { rm -rf "$SANDBOX"; }

@test "restore.sh --dry-run writes nothing" {
  run bash "$SB_ROOT/restore.sh" --dry-run
  [ "$status" -eq 0 ]
  [ ! -f "$SB_OSRELEASE" ]
  [ ! -f "$SB_LDD" ]
  [ ! -f "$SANDBOX/mount.log" ]
  [[ "$output" == *"[dry-run]"* ]]
}

@test "restore.sh writes ldd shim that reports glibc >= 2.13" {
  run bash "$SB_ROOT/restore.sh"
  [ "$status" -eq 0 ]
  [ -x "$SB_LDD" ]
  run "$SB_LDD" --version
  [[ "$output" == *"synobrew shim"* ]]
  [[ "$output" == *"2.36"* ]]
}

@test "restore.sh writes DSM-derived os-release" {
  run bash "$SB_ROOT/restore.sh"
  [ "$status" -eq 0 ]
  grep -q 'ID=synology' "$SB_OSRELEASE"
  grep -q 'PRETTY_NAME="Synology DSM 7.2.1"' "$SB_OSRELEASE"
}

@test "restore.sh calls mount with bind when not mounted" {
  run bash "$SB_ROOT/restore.sh"
  [ "$status" -eq 0 ]
  grep -q -- "-o bind" "$SANDBOX/mount.log"
}

@test "restore.sh is idempotent (second run keeps the shim)" {
  bash "$SB_ROOT/restore.sh"
  run bash "$SB_ROOT/restore.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ldd shim already present"* ]]
}

@test "restore.sh keeps a pre-existing non-synobrew ldd (does not clobber a real ldd)" {
  printf '#!/bin/sh\necho "ldd (Ubuntu GLIBC 2.31-0ubuntu9) 2.31"\n' > "$SB_LDD"
  chmod +x "$SB_LDD"
  local before; before="$(cksum < "$SB_LDD")"
  run bash "$SB_ROOT/restore.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"keeping existing non-synobrew ldd"* ]]
  ! grep -q 'synobrew shim' "$SB_LDD"            # not overwritten with our shim
  [ "$(cksum < "$SB_LDD")" = "$before" ]         # byte-for-byte unchanged
}
