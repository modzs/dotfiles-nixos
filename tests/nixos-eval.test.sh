#!/usr/bin/env bash
# Behaviour tests for the NixOS configuration this flake declares.
#
# The claim under test is the strongest one this repo can honestly make about a
# machine that does not exist yet: the configuration EVALUATES. Evaluating
# `system.build.toplevel` down to its derivation path type-checks every module -
# NixOS, Home Manager, and this repo's own - and resolves every package
# attribute, option name and value against the pinned nixpkgs. It catches a
# renamed option, a package that is not in this channel, and a typo anywhere in
# the tree, and it needs no Linux builder, so it runs on any machine with Nix.
#
# What it deliberately does NOT claim: that the system builds, activates, or
# boots. A derivation path is a plan, not a result. Nothing in this repository
# has been built or booted on real hardware; see README.md.
#
# Coverage:
# - the whole configuration evaluates to a system derivation;
# - the `hostName` in flake.nix actually reaches networking.hostName, so the one
#   line bootstrap.sh rewrites is wired to something;
# - the configured user's home is a Linux /home path, not the /Users path this
#   configuration was converted from;
# - that user's login shell is the zsh the system module enables.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

dotfiles_test_parse_args "$@"

# The flake output name. bootstrap.sh and rebuild.sh name the same one.
CONFIG=pc

FACTS=""
FACTS_ERROR=""
FACTS_SKIP=""

# One evaluation, several facts. Everything below reads from this, so the whole
# file costs a single nix invocation rather than one per check.
#
# Sets FACTS to `key<TAB>value` lines, or FACTS_SKIP to the reason no evaluation
# could be attempted, or FACTS_ERROR to nix's own complaint.
collect_facts() {
  local expr status=0

  if ! command -v nix >/dev/null 2>&1; then
    FACTS_SKIP="nix not found"
    return 0
  fi
  # Nix is present, but this repo needs the flakes and nix-command features that
  # a stock nix.conf still gates. Probe for them separately, so a machine that
  # cannot evaluate flakes at all reports `skip -` rather than blaming the
  # configuration for its own inability to read it.
  if ! nix flake metadata --no-write-lock-file "$ROOT" >/dev/null 2>&1; then
    FACTS_SKIP="this nix cannot read a flake (nix-command and flakes not enabled?)"
    return 0
  fi

  # `builtins.attrNames` of the Home Manager users, rather than re-parsing
  # flake.nix: the fact worth asserting is what the evaluated configuration says
  # about its user, not what a regex finds in a file.
  expr='cfg:
    let
      user = builtins.head (builtins.attrNames cfg.config.home-manager.users);
      hm = cfg.config.home-manager.users.${user};
    in builtins.concatStringsSep "\n" [
      "drvPath\t${cfg.config.system.build.toplevel.drvPath}"
      "hostName\t${cfg.config.networking.hostName}"
      "system\t${cfg.config.nixpkgs.hostPlatform.system}"
      "user\t${user}"
      "homeDirectory\t${hm.home.homeDirectory}"
      "loginShell\t${cfg.config.users.users.${user}.shell.pname or "?"}"
      "stateVersion\t${cfg.config.system.stateVersion}"
    ]'

  FACTS=$(nix eval --raw --no-write-lock-file --apply "$expr" \
    "$ROOT#nixosConfigurations.$CONFIG" 2>"$ROOT/.nixos-eval.err") || status=$?
  if [ "$status" != 0 ]; then
    FACTS_ERROR=$(cat "$ROOT/.nixos-eval.err" 2>/dev/null || true)
    FACTS=""
  fi
  rm -f "$ROOT/.nixos-eval.err"
}

fact() {
  printf '%s\n' "$FACTS" | sed -n "s/^$1"$'\t'"//p" | head -n1
}

# --- the configuration evaluates ----------------------------------------------

test_configuration_evaluates_to_a_system_derivation() {
  local drv
  if [ -n "$FACTS_SKIP" ]; then
    skip "NixOS configuration evaluation ($FACTS_SKIP)"
    return 0
  fi
  if [ -n "$FACTS_ERROR" ]; then
    fail "the NixOS configuration does not evaluate: $(printf '%s' "$FACTS_ERROR" | tail -n 20 | tr '\n' ' ')"
  fi

  drv=$(fact drvPath)
  case $drv in
    /nix/store/*-nixos-system-*.drv) : ;;
    *) fail "system.build.toplevel evaluated to '$drv', which is not a NixOS system derivation" ;;
  esac

  pass "nixos: the configuration evaluates to $drv"
}

# --- flake.nix's hostName reaches the system ----------------------------------
#
# bootstrap.sh personalizes the machine by rewriting one line in flake.nix. If
# that value stopped being threaded through specialArgs into
# networking.hostName, the rewrite would keep succeeding and mean nothing.

test_flake_hostname_reaches_the_system() {
  local declared evaluated
  if [ -n "$FACTS_SKIP" ]; then
    skip "hostName wiring ($FACTS_SKIP)"
    return 0
  fi
  [ -z "$FACTS_ERROR" ] || fail "the configuration did not evaluate, so nothing could be read from it"

  declared=$(sed -nE 's/^[[:space:]]*hostName = "([^"]+)";.*/\1/p' "$ROOT/flake.nix" | head -n1)
  [ -n "$declared" ] || fail "flake.nix declares no single hostName line for bootstrap.sh to rewrite"
  evaluated=$(fact hostName)
  [ "$declared" = "$evaluated" ] \
    || fail "flake.nix says hostName '$declared' but the system evaluates to '$evaluated'"

  pass "nixos: the hostName in flake.nix is the one the system configures ($evaluated)"
}

# --- the Linux adjustments are real -------------------------------------------
#
# This configuration was converted from a nix-darwin one, where the home
# directory is /Users/<name> and the login shell is set a completely different
# way. Both are easy to carry over unchanged from the sibling repo and neither
# would fail to evaluate.

test_home_directory_is_a_linux_path() {
  local user home
  if [ -n "$FACTS_SKIP" ]; then
    skip "home directory platform check ($FACTS_SKIP)"
    return 0
  fi
  [ -z "$FACTS_ERROR" ] || fail "the configuration did not evaluate, so nothing could be read from it"

  user=$(fact user)
  home=$(fact homeDirectory)
  [ "$home" = "/home/$user" ] \
    || fail "home.homeDirectory is '$home', not the Linux /home/$user"
  [ "$(fact system)" = "x86_64-linux" ] \
    || fail "the configuration builds for '$(fact system)', not x86_64-linux"

  pass "nixos: the configured home is $home on $(fact system)"
}

# NixOS only accepts a login shell some system module has put in /etc/shells, so
# `users.users.<user>.shell = pkgs.zsh` without `programs.zsh.enable` is a
# configuration that evaluates and then leaves the user without their shell.
test_login_shell_is_zsh() {
  if [ -n "$FACTS_SKIP" ]; then
    skip "login shell check ($FACTS_SKIP)"
    return 0
  fi
  [ -z "$FACTS_ERROR" ] || fail "the configuration did not evaluate, so nothing could be read from it"

  [ "$(fact loginShell)" = zsh ] \
    || fail "the configured login shell is '$(fact loginShell)', not zsh"
  grep -q '^[[:space:]]*programs\.zsh\.enable = true;' "$ROOT/configuration.nix" \
    || fail "zsh is the login shell but configuration.nix does not enable it at system level, so NixOS would not offer it"

  pass "nixos: the user's login shell is zsh, and the system enables zsh"
}

collect_facts

test_configuration_evaluates_to_a_system_derivation
test_flake_hostname_reaches_the_system
test_home_directory_is_a_linux_path
test_login_shell_is_zsh

test_summary 4
