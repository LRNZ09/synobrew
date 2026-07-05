# Shared bats bootstrap. Sets SB_ROOT to the repo root and sources lib/common.sh.
load_common() {
  SB_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
  export SB_ROOT
  # shellcheck source=/dev/null
  source "${SB_ROOT}/lib/common.sh"
}
