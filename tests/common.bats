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
