#!/usr/bin/env bash
# Behaviour tests for lib/npm-globals.sh - the pinned agent-CLI install step that
# home.activation.agentNpmCLIs runs on every single rebuild.
#
# Each case runs the real, unmodified script against a sandboxed npm prefix with
# fake `node` and `npm` executables that record their arguments and environment
# instead of doing anything. Nothing here touches the real ~/.npm-global, the
# network, or a real npm.
#
# Coverage - the contract at the top of lib/npm-globals.sh, whose first three
# promises README.md also states as fact:
# - every pinned version already installed: not one npm call, so zero network;
# - a differing version, and an absent package: installed at exactly the pin;
# - a failed install: warns, keeps going, and does not abort the switch;
# - DRY_RUN: reports what it would install and installs nothing.
# Plus: a miswired call from home.nix fails loudly instead of warning forever.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

dotfiles_test_parse_args "$@"

TMP_ROOT=$(dotfiles_test_tmproot dotfiles-npm-globals)

SCRIPT="$ROOT/lib/npm-globals.sh"

# --- sandbox -----------------------------------------------------------------

# Build a disposable sandbox and echo its root. Layout:
#   <sb>/nodebin      fake node / npm, invoked by absolute path like the real ones
#   <sb>/prefix       the fake npm global prefix
#   <sb>/calls.log    every fake invocation, in order
#   <sb>/npm.env      NPM_CONFIG_PREFIX and PATH as npm saw them
# $1 (optional) is the exit status the fake npm should return.
make_sandbox() {
  local npm_status=${1:-0} sb
  sb=$(mktemp -d "$TMP_ROOT/case.XXXXXX") || fail "could not create a sandbox"
  case $sb in
    "$TMP_ROOT"/*) [ -d "$sb" ] || fail "sandbox $sb was not created" ;;
    *) fail "sandbox path escaped the test temp root: '$sb'" ;;
  esac
  mkdir -p "$sb/nodebin" "$sb/prefix"

  # `node -p "require('<manifest>').version"` is the only way the script uses
  # node. The fake answers it by reading the version out of the JSON, so the
  # version guard is exercised for real rather than stubbed to a constant.
  cat >"$sb/nodebin/node" <<SHIM
#!/bin/sh
echo "node \$*" >>"$sb/calls.log"
expr=\$2
manifest=\$(printf '%s' "\$expr" | sed -n "s/^require('\(.*\)')\.version\$/\1/p")
[ -n "\$manifest" ] || exit 1
[ -r "\$manifest" ] || exit 1
version=\$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "\$manifest")
[ -n "\$version" ] || exit 1
echo "\$version"
SHIM

  cat >"$sb/nodebin/npm" <<SHIM
#!/bin/sh
echo "npm \$*" >>"$sb/calls.log"
{
  echo "NPM_CONFIG_PREFIX=\$NPM_CONFIG_PREFIX"
  echo "PATH=\$PATH"
} >>"$sb/npm.env"
exit $npm_status
SHIM
  chmod +x "$sb/nodebin/node" "$sb/nodebin/npm"

  printf '%s\n' "$sb"
}

# Pretend <name> is installed at <version> in the sandbox prefix.
install_fixture() {
  local sb=$1 name=$2 version=$3 dir
  dir="$sb/prefix/lib/node_modules/$name"
  mkdir -p "$dir"
  printf '{ "name": "%s", "version": "%s" }\n' "$name" "$version" >"$dir/package.json"
}

# Run lib/npm-globals.sh in a sandbox.
#   $1 sandbox root, $2 "dry" to set DRY_RUN or "" for a live run, rest: specs
# Writes stdout to <sb>/out and stderr to <sb>/err, and echoes the exit status.
run_npm_globals() {
  local sb=$1 mode=$2 status=0
  shift 2
  case "$sb/prefix" in
    "$TMP_ROOT"/*) : ;;
    *) fail "refusing to run with a prefix outside the test temp root" ;;
  esac
  if [ "$mode" = dry ]; then
    env DRY_RUN=1 "$BASH" "$SCRIPT" "$sb/nodebin" "$sb/prefix" "$@" \
      >"$sb/out" 2>"$sb/err" || status=$?
  else
    env -u DRY_RUN "$BASH" "$SCRIPT" "$sb/nodebin" "$sb/prefix" "$@" \
      >"$sb/out" 2>"$sb/err" || status=$?
  fi
  printf '%s\n' "$status"
}

# Run lib/npm-globals.sh with the argument list given verbatim, so the two
# directory arguments themselves can be got wrong. Runs with the sandbox as the
# working directory, so a relative path the script ought to reject cannot reach
# the repo even if the rejection regresses.
run_npm_globals_raw() {
  local sb=$1 status=0
  shift
  ( cd "$sb" && env -u DRY_RUN "$BASH" "$SCRIPT" "$@" ) \
    >"$sb/out" 2>"$sb/err" || status=$?
  printf '%s\n' "$status"
}

sandbox_out() { cat "$1/out"; }
sandbox_err() { cat "$1/err"; }
sandbox_calls() { cat "$1/calls.log" 2>/dev/null || true; }
npm_calls() { grep '^npm ' "$1/calls.log" 2>/dev/null || true; }
npm_call_count() { npm_calls "$1" | grep -c . | tr -d ' '; }

# --- promise 1: nothing to change means no network ----------------------------

test_all_pinned_versions_present_makes_no_npm_call() {
  local sb status
  sb=$(make_sandbox)
  install_fixture "$sb" gh-axi 0.1.35
  install_fixture "$sb" lavish-axi 0.1.67
  status=$(run_npm_globals "$sb" live gh-axi@0.1.35 lavish-axi@0.1.67)

  [ "$status" = 0 ] || fail "the script failed with everything already installed: $(sandbox_err "$sb")"
  [ -z "$(npm_calls "$sb")" ] \
    || fail "npm was called with nothing to change: $(npm_calls "$sb")"
  assert_not_contains "$(sandbox_out "$sb")" "installing" \
    "the script claimed to install something with nothing to change"

  pass "up to date: every pinned version present means npm is never invoked"
}

# --- promise 2: exactly the pinned version, into the given prefix --------------

test_absent_package_is_installed_at_the_pinned_version() {
  local sb status
  sb=$(make_sandbox)
  status=$(run_npm_globals "$sb" live gh-axi@0.1.35)

  [ "$status" = 0 ] || fail "the script failed installing an absent package: $(sandbox_err "$sb")"
  [ "$(npm_call_count "$sb")" = 1 ] \
    || fail "expected exactly one npm call, got: $(npm_calls "$sb")"
  [ "$(npm_calls "$sb")" = "npm install --global --no-fund --no-audit gh-axi@0.1.35" ] \
    || fail "npm was not called with the pinned spec: $(npm_calls "$sb")"
  assert_contains "$(cat "$sb/npm.env")" "NPM_CONFIG_PREFIX=$sb/prefix" \
    "npm was not pointed at the prefix it was given"
  assert_contains "$(cat "$sb/npm.env")" "PATH=$sb/nodebin:" \
    "npm did not get the given node directory first on PATH"

  pass "absent: a missing package is installed at exactly the pinned version"
}

test_wrong_version_is_reinstalled_at_the_pinned_version() {
  local sb status
  sb=$(make_sandbox)
  install_fixture "$sb" gh-axi 0.1.30
  status=$(run_npm_globals "$sb" live gh-axi@0.1.35)

  [ "$status" = 0 ] || fail "the script failed upgrading a package: $(sandbox_err "$sb")"
  [ "$(npm_calls "$sb")" = "npm install --global --no-fund --no-audit gh-axi@0.1.35" ] \
    || fail "an outdated package was not reinstalled at the pin: $(npm_calls "$sb")"

  pass "drift: an installed version that differs from the pin is reinstalled at the pin"
}

# A pin is not "at least": downgrading is exactly as much a version change as
# upgrading, and an unpinned `npm install -g name` would silently ignore it.
test_newer_installed_version_is_pinned_back_down() {
  local sb status
  sb=$(make_sandbox)
  install_fixture "$sb" gh-axi 0.2.0
  status=$(run_npm_globals "$sb" live gh-axi@0.1.35)

  [ "$status" = 0 ] || fail "the script failed downgrading a package: $(sandbox_err "$sb")"
  [ "$(npm_calls "$sb")" = "npm install --global --no-fund --no-audit gh-axi@0.1.35" ] \
    || fail "a newer installed version was not pinned back down: $(npm_calls "$sb")"

  pass "drift: an installed version newer than the pin is still reinstalled at the pin"
}

test_only_the_drifted_spec_is_installed() {
  local sb status
  sb=$(make_sandbox)
  install_fixture "$sb" gh-axi 0.1.35
  install_fixture "$sb" lavish-axi 0.1.60
  install_fixture "$sb" quota-axi 0.1.40
  status=$(run_npm_globals "$sb" live gh-axi@0.1.35 lavish-axi@0.1.67 quota-axi@0.1.40)

  [ "$status" = 0 ] || fail "the script failed on a mixed set: $(sandbox_err "$sb")"
  [ "$(npm_call_count "$sb")" = 1 ] \
    || fail "expected only the drifted spec to be installed, got: $(npm_calls "$sb")"
  [ "$(npm_calls "$sb")" = "npm install --global --no-fund --no-audit lavish-axi@0.1.67" ] \
    || fail "the wrong spec was installed: $(npm_calls "$sb")"

  pass "mixed: only the spec whose version drifted is installed"
}

# An unreadable or corrupt manifest must not be mistaken for a match: node exits
# non-zero, the guard sees no version, and the pin is installed anyway.
test_unreadable_manifest_is_treated_as_not_installed() {
  local sb status dir
  sb=$(make_sandbox)
  dir="$sb/prefix/lib/node_modules/gh-axi"
  mkdir -p "$dir"
  printf 'not json\n' >"$dir/package.json"
  status=$(run_npm_globals "$sb" live gh-axi@0.1.35)

  [ "$status" = 0 ] || fail "the script failed on a corrupt manifest: $(sandbox_err "$sb")"
  [ "$(npm_calls "$sb")" = "npm install --global --no-fund --no-audit gh-axi@0.1.35" ] \
    || fail "a corrupt manifest did not lead to an install: $(npm_calls "$sb")"

  pass "corrupt: an unreadable manifest counts as not installed, so the pin is installed"
}

# --- promise 3: a failed install warns, it does not abort the switch ----------

test_failed_install_warns_and_succeeds() {
  local sb status
  sb=$(make_sandbox 1)
  status=$(run_npm_globals "$sb" live gh-axi@0.1.35)

  [ "$status" = 0 ] \
    || fail "a failed install aborted the activation with status $status: $(sandbox_err "$sb")"
  assert_contains "$(sandbox_err "$sb")" "warning: could not install gh-axi@0.1.35" \
    "a failed install did not warn"
  assert_contains "$(sandbox_err "$sb")" "Keeping nothing." \
    "the warning did not say what was kept when nothing was installed"

  pass "offline: a failed install warns and still lets the switch continue"
}

test_failed_install_reports_the_version_it_kept() {
  local sb status
  sb=$(make_sandbox 1)
  install_fixture "$sb" gh-axi 0.1.30
  status=$(run_npm_globals "$sb" live gh-axi@0.1.35)

  [ "$status" = 0 ] || fail "a failed upgrade aborted the activation: $(sandbox_err "$sb")"
  assert_contains "$(sandbox_err "$sb")" "Keeping 0.1.30." \
    "the warning did not report the version left in place"

  pass "offline: a failed upgrade reports the version it kept"
}

test_failed_install_does_not_stop_later_specs() {
  local sb status
  sb=$(make_sandbox 1)
  status=$(run_npm_globals "$sb" live gh-axi@0.1.35 lavish-axi@0.1.67)

  [ "$status" = 0 ] || fail "a failed install aborted the activation: $(sandbox_err "$sb")"
  [ "$(npm_call_count "$sb")" = 2 ] \
    || fail "a failed install stopped the remaining specs: $(npm_calls "$sb")"
  assert_contains "$(npm_calls "$sb")" "lavish-axi@0.1.67" \
    "the spec after the failing one was never attempted"

  pass "offline: a failed install does not stop the specs after it"
}

# --- promise 4: DRY_RUN reports and changes nothing ---------------------------

test_dry_run_reports_and_installs_nothing() {
  local sb status
  sb=$(make_sandbox)
  install_fixture "$sb" gh-axi 0.1.35
  status=$(run_npm_globals "$sb" dry gh-axi@0.1.35 lavish-axi@0.1.67)

  [ "$status" = 0 ] || fail "the script failed under DRY_RUN: $(sandbox_err "$sb")"
  [ -z "$(npm_calls "$sb")" ] \
    || fail "DRY_RUN installed something: $(npm_calls "$sb")"
  assert_contains "$(sandbox_out "$sb")" "would install lavish-axi@0.1.67 into $sb/prefix" \
    "DRY_RUN did not report the install it would have done"
  assert_not_contains "$(sandbox_out "$sb")" "would install gh-axi" \
    "DRY_RUN reported an install for an already-current package"
  [ ! -e "$sb/npm.env" ] || fail "npm ran under DRY_RUN"

  pass "dry run: DRY_RUN reports what it would install and installs nothing"
}

# --- promise 5: a miswired call fails loudly ----------------------------------
#
# The two directory arguments come from home.activation.agentNpmCLIs, and getting
# them wrong is a bug in this repo, not a condition of the machine. Without these
# guards a swap is silent: the version guard reads manifests under the node store
# path (never there), then invokes <prefix>/npm (does not exist), and the failed
# install is swallowed by the offline tolerance - so every rebuild warns
# "offline?" and installs nothing, forever, without failing the switch.

test_swapped_directory_arguments_fail_loudly_and_install_nothing() {
  local sb status
  sb=$(make_sandbox)
  status=$(run_npm_globals_raw "$sb" "$sb/prefix" "$sb/nodebin" gh-axi@0.1.35)

  [ "$status" != 0 ] || fail "swapped directory arguments were accepted silently"
  assert_contains "$(sandbox_err "$sb")" "no executable npm in node bin directory" \
    "the failure did not name the argument that was wrong"
  assert_not_contains "$(sandbox_err "$sb")" "offline?" \
    "a wiring error was reported as an offline machine"
  [ -z "$(sandbox_calls "$sb")" ] \
    || fail "a miswired call still ran something: $(sandbox_calls "$sb")"
  [ ! -e "$sb/prefix/lib" ] || fail "a miswired call wrote into the prefix"

  pass "wiring: swapped directory arguments fail loudly and install nothing"
}

test_relative_npm_prefix_is_rejected() {
  local sb status
  sb=$(make_sandbox)
  status=$(run_npm_globals_raw "$sb" "$sb/nodebin" prefix gh-axi@0.1.35)

  [ "$status" != 0 ] || fail "a relative npm prefix was accepted"
  assert_contains "$(sandbox_err "$sb")" "npm prefix must be an absolute path" \
    "the failure did not name the relative prefix as the problem"
  [ -z "$(sandbox_calls "$sb")" ] \
    || fail "a relative prefix still ran something: $(sandbox_calls "$sb")"

  pass "wiring: an npm prefix that is not an absolute path is rejected"
}

# The version guard reads the installed version with `node`, so a bin directory
# carrying npm but not node breaks promise 1 rather than promise 2: every
# manifest read yields an empty version, nothing ever matches its pin, and the
# rebuild reinstalls every CLI over the network, converging never and erroring
# never. The fixture below is already at exactly its pinned version, so an
# install of any kind is the regression.
test_node_bin_directory_without_node_is_rejected() {
  local sb status
  sb=$(make_sandbox)
  install_fixture "$sb" gh-axi 0.1.35
  rm "$sb/nodebin/node"
  status=$(run_npm_globals_raw "$sb" "$sb/nodebin" "$sb/prefix" gh-axi@0.1.35)

  [ "$status" != 0 ] || fail "a node bin directory with no node was accepted"
  assert_contains "$(sandbox_err "$sb")" "no executable node in node bin directory" \
    "the failure did not name node as the problem"
  assert_not_contains "$(sandbox_err "$sb")" "offline?" \
    "a wiring error was reported as an offline machine"
  [ -z "$(sandbox_calls "$sb")" ] \
    || fail "an up-to-date pin was reinstalled with node missing: $(sandbox_calls "$sb")"

  pass "wiring: a node bin directory with npm but no node is rejected"
}

test_all_pinned_versions_present_makes_no_npm_call
test_absent_package_is_installed_at_the_pinned_version
test_wrong_version_is_reinstalled_at_the_pinned_version
test_newer_installed_version_is_pinned_back_down
test_only_the_drifted_spec_is_installed
test_unreadable_manifest_is_treated_as_not_installed
test_failed_install_warns_and_succeeds
test_failed_install_reports_the_version_it_kept
test_failed_install_does_not_stop_later_specs
test_dry_run_reports_and_installs_nothing
test_swapped_directory_arguments_fail_loudly_and_install_nothing
test_relative_npm_prefix_is_rejected
test_node_bin_directory_without_node_is_rejected

test_summary 13
