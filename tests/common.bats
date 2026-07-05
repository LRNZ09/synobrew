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
