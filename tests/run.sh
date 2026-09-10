#!/usr/bin/env bash
# tests/run.sh - run every tests/*.test.sh and report the combined result.
#
#   ./tests/run.sh              run everything, report what was skipped
#   ./tests/run.sh --strict     treat any skipped check as a failure
#
# --strict is what CI uses: a suite that skips most of its checks because the
# tools they need are absent must not be able to report success.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# How many test files this suite is made of. Each file asserts its own check
# count through test_summary, which catches a check that quietly stopped being
# run; nothing inside a file can notice the file itself disappearing from the
# glob, so that count lives here. Change it in the same commit that adds or
# removes a tests/*.test.sh.
EXPECTED_SUITES=8

TALLY=$(mktemp "${TMPDIR:-/tmp}/dotfiles-test-tally.XXXXXX")
trap 'rm -f "$TALLY"' EXIT
export DOTFILES_TEST_TALLY="$TALLY"

status=0
suites=0
for suite in "$ROOT"/tests/*.test.sh; do
  suites=$((suites + 1))
  printf '# %s\n' "${suite#"$ROOT"/}"
  /bin/bash "$suite" "$@" || status=1
done

passed=0
skipped=0
while read -r p s; do
  passed=$((passed + p))
  skipped=$((skipped + s))
done <"$TALLY"

printf '\n# total: %d ok, %d skipped, across %d test file(s)\n' \
  "$passed" "$skipped" "$suites"

if [ "$suites" != "$EXPECTED_SUITES" ]; then
  printf 'not ok - expected %d test file(s), ran %d\n' "$EXPECTED_SUITES" "$suites" >&2
  status=1
fi

exit "$status"
