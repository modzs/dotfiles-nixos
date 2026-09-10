#!/usr/bin/env bash
# tests/lib.sh - shared primitives for dotfiles behavior tests.
#
# Source this from a test file:
#   # shellcheck source=tests/lib.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# ROOT is exported as the repository root (this file lives in tests/).

if [ -n "${DOTFILES_TEST_LIB_SOURCED:-}" ]; then
  return 0
fi
DOTFILES_TEST_LIB_SOURCED=1

# shellcheck disable=SC2034
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- result accounting -------------------------------------------------------
#
# A skipped check is not a passing check. Every test either passes or says out
# loud what it could not run, the counts are reported at the end of the file,
# and --strict turns any skip into a failure so CI can demand the full suite.

DOTFILES_TEST_PASSED=0
DOTFILES_TEST_SKIPPED=0
DOTFILES_TEST_STRICT=${DOTFILES_TEST_STRICT:-0}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  DOTFILES_TEST_PASSED=$((DOTFILES_TEST_PASSED + 1))
  printf 'ok - %s\n' "$1"
}

# skip "<what was not checked> (<what was unavailable>)"
skip() {
  DOTFILES_TEST_SKIPPED=$((DOTFILES_TEST_SKIPPED + 1))
  printf 'skip - %s\n' "$1"
}

# Call once at the end of a test file, after the last test function, with the
# number of checks that file is supposed to report.
#
#   test_summary 13
#
# The count is asserted, not just printed. Without it, deleting a call to a test
# function - or an early `return 0` that silently stops the file halfway -
# reports a smaller number of passing checks, which reads exactly like success.
# The suite has to be able to tell "everything passed" from "less of it ran".
# Skips count towards the total: a check that reports `skip -` did run and did
# report, it just could not do its work here.
test_summary() {
  local expected=${1:-} total=$((DOTFILES_TEST_PASSED + DOTFILES_TEST_SKIPPED))
  printf '%d ok, %d skipped\n' "$DOTFILES_TEST_PASSED" "$DOTFILES_TEST_SKIPPED"
  # tests/run.sh sets this to aggregate counts across test files.
  if [ -n "${DOTFILES_TEST_TALLY:-}" ]; then
    printf '%d %d\n' "$DOTFILES_TEST_PASSED" "$DOTFILES_TEST_SKIPPED" >>"$DOTFILES_TEST_TALLY"
  fi
  if [ -z "$expected" ]; then
    fail "test_summary was called without the expected check count"
  fi
  if [ "$total" != "$expected" ]; then
    fail "expected $expected check(s), $total reported: a check was dropped, added, or stopped early"
  fi
  if [ "$DOTFILES_TEST_STRICT" = 1 ] && [ "$DOTFILES_TEST_SKIPPED" -gt 0 ]; then
    fail "--strict: $DOTFILES_TEST_SKIPPED check(s) skipped"
  fi
}

# Test files pass their own "$@" here.
dotfiles_test_parse_args() {
  while [ "$#" -gt 0 ]; do
    case $1 in
      --strict) DOTFILES_TEST_STRICT=1 ;;
      *) fail "unknown option: $1" ;;
    esac
    shift
  done
}

# --- self-cleaning temp root -------------------------------------------------
#
# The roots to remove are recorded in a file, and the EXIT trap is installed
# here, at source time, in the test file's own shell. Both details matter:
# callers write `TMP_ROOT=$(dotfiles_test_tmproot ...)`, and a trap registered
# inside that command substitution fires the moment the substitution ends -
# deleting the temp root before a single test can use it. A shell variable
# appended to in there would be lost for the same reason.

DOTFILES_TEST_CLEANUP_LIST=$(mktemp "${TMPDIR:-/tmp}/dotfiles-test-cleanup.XXXXXX")

dotfiles_test_cleanup() {
  local d
  [ -f "$DOTFILES_TEST_CLEANUP_LIST" ] || return 0
  while IFS= read -r d; do
    [ -n "$d" ] && rm -rf "$d"
  done <"$DOTFILES_TEST_CLEANUP_LIST"
  rm -f "$DOTFILES_TEST_CLEANUP_LIST"
}
trap dotfiles_test_cleanup EXIT

dotfiles_test_tmproot() {
  local prefix=${1:-dotfiles-test} root
  root=$(mktemp -d "${TMPDIR:-/tmp}/${prefix}.XXXXXX") \
    || fail "could not create a temp root for $prefix"
  [ -d "$root" ] || fail "mktemp -d did not produce a directory for $prefix"
  printf '%s\n' "$root" >>"$DOTFILES_TEST_CLEANUP_LIST"
  printf '%s\n' "$root"
}

# --- assertions ---------------------------------------------------------------

assert_contains() {
  local haystack=$1 needle=$2 message=$3
  case "$haystack" in
    *"$needle"*) : ;;
    *) fail "$message" ;;
  esac
}

assert_not_contains() {
  local haystack=$1 needle=$2 message=$3
  case "$haystack" in
    *"$needle"*) fail "$message" ;;
    *) : ;;
  esac
}

# --- deterministic git fixtures ------------------------------------------------

dotfiles_git_init_commit() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# %s\n' "$(basename "$dir")" > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name=dotfiles-test -c user.email=dotfiles-test@example.invalid \
    commit -qm "fixture"
}
