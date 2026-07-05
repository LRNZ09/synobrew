#!/usr/bin/env bats

load test_helper

setup() { load_common; }

@test "sb_classify_arch: x86_64 is supported" {
  run sb_classify_arch x86_64
  [ "$status" -eq 0 ]
  [ "$output" = "supported" ]
}

@test "sb_classify_arch: aarch64 warns" {
  run sb_classify_arch aarch64
  [ "$output" = "warn" ]
}

@test "sb_classify_arch: armv7l is blocked" {
  run sb_classify_arch armv7l
  [ "$output" = "blocked" ]
}

@test "sb_classify_arch: empty is blocked" {
  run sb_classify_arch ""
  [ "$output" = "blocked" ]
}

@test "sb_version_ge: equal versions" {
  run sb_version_ge 2.36 2.36
  [ "$status" -eq 0 ]
}

@test "sb_version_ge: higher is >=" {
  run sb_version_ge 2.36 2.13
  [ "$status" -eq 0 ]
}

@test "sb_version_ge: lower is not >=" {
  run sb_version_ge 2.12 2.13
  [ "$status" -ne 0 ]
}

@test "sb_dsm_tier: 7.2 ok" {
  run sb_dsm_tier 7 2
  [ "$output" = "ok" ]
}

@test "sb_dsm_tier: 7.1 warn" {
  run sb_dsm_tier 7 1
  [ "$output" = "warn" ]
}

@test "sb_dsm_tier: 7.0 blocked" {
  run sb_dsm_tier 7 0
  [ "$output" = "blocked" ]
}

@test "sb_dsm_tier: 6.x blocked" {
  run sb_dsm_tier 6 2
  [ "$output" = "blocked" ]
}

@test "sb_dsm_tier: 8.x ok" {
  run sb_dsm_tier 8 0
  [ "$output" = "ok" ]
}

@test "sb_parse_glibc: extracts from banner" {
  run sb_parse_glibc "GNU C Library (GNU libc) stable release version 2.36."
  [ "$output" = "2.36" ]
}

@test "sb_parse_glibc: empty when absent" {
  run sb_parse_glibc "no version here"
  [ "$output" = "" ]
}

@test "sb_shell_from_path: fish" {
  run sb_shell_from_path /opt/homebrew/bin/fish
  [ "$output" = "fish" ]
}

@test "sb_shell_from_path: bash" {
  run sb_shell_from_path /bin/bash
  [ "$output" = "bash" ]
}

@test "sb_shell_from_path: unknown" {
  run sb_shell_from_path /usr/bin/nu
  [ "$output" = "other" ]
}

@test "sb_rc_file: fish -> config.fish" {
  run sb_rc_file fish /home/bob
  [ "$output" = "/home/bob/.config/fish/config.fish" ]
}

@test "sb_rc_file: zsh -> .zshrc" {
  run sb_rc_file zsh /home/bob
  [ "$output" = "/home/bob/.zshrc" ]
}

@test "sb_rc_file: bash -> .profile" {
  run sb_rc_file bash /home/bob
  [ "$output" = "/home/bob/.profile" ]
}

@test "sb_shellenv_line: fish form" {
  run sb_shellenv_line fish /home/linuxbrew/.linuxbrew/bin/brew
  [ "$output" = "/home/linuxbrew/.linuxbrew/bin/brew shellenv fish | source" ]
}

@test "sb_shellenv_line: bash form" {
  run sb_shellenv_line bash /home/linuxbrew/.linuxbrew/bin/brew
  [ "$output" = 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' ]
}

@test "sb_bak_name" {
  run sb_bak_name /etc/os-release 1720000000
  [ "$output" = "/etc/os-release.synobrew.bak-1720000000" ]
}

@test "sb_classify_state: managed" {
  run sb_classify_state 1 1 1 0
  [ "$output" = "managed" ]
}

@test "sb_classify_state: foreign-backing when mounted elsewhere" {
  run sb_classify_state 1 1 0 0
  [ "$output" = "foreign-backing" ]
}

@test "sb_classify_state: foreign-backing when brew present but not mounted" {
  run sb_classify_state 1 0 0 0
  [ "$output" = "foreign-backing" ]
}

@test "sb_classify_state: foreign-prefix" {
  run sb_classify_state 0 0 0 1
  [ "$output" = "foreign-prefix" ]
}

@test "sb_classify_state: fresh" {
  run sb_classify_state 0 0 0 0
  [ "$output" = "fresh" ]
}

@test "sb_dev_inode: returns dev:inode for existing path" {
  run sb_dev_inode "$SB_ROOT/lib/common.sh"
  [ -n "$output" ]
  [[ "$output" == *:* ]]
}

@test "sb_dev_inode: empty for missing path" {
  run sb_dev_inode /no/such/path/xyz
  [ "$output" = "" ]
}
