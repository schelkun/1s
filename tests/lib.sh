# shellcheck shell=bash
# Minimal test helpers.

TESTS_RUN=0
TESTS_FAILED=0

pass() { TESTS_RUN=$((TESTS_RUN + 1)); printf '  ok   %s\n' "$1"; }
fail() { TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1)); printf '  FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '       %s\n' "$2"; }

assert_eq() { # NAME EXPECTED ACTUAL
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "expected '$2', got '$3'"; fi
}
assert_ok()   { local n="$1"; shift; if "$@" >/dev/null 2>&1; then pass "${n}"; else fail "${n}" "command failed: $*"; fi; }
assert_fail() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then fail "${n}" "command unexpectedly succeeded: $*"; else pass "${n}"; fi; }
assert_contains() { # NAME FILE PATTERN (grep -E)
  if grep -qE -- "$3" "$2"; then pass "$1"; else fail "$1" "'$3' not found in $2"; fi
}
assert_not_contains() {
  if grep -qE -- "$3" "$2"; then fail "$1" "'$3' unexpectedly found in $2"; else pass "$1"; fi
}

summary() {
  echo
  if (( TESTS_FAILED )); then echo "FAILED: ${TESTS_FAILED}/${TESTS_RUN}"; exit 1; fi
  echo "PASSED: ${TESTS_RUN} tests"
}
