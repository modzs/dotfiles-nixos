#!/usr/bin/env bash
# Behaviour tests for the nixpkgs input this flake tracks.
#
# The property under test is not which branch name appears in flake.nix. It is
# the thing the user actually feels: a routine ./rebuild.sh is served from the
# binary cache instead of compiling packages locally. So both checks ask the
# systems that really decide that, rather than reading the config as text:
#
# - channels.nixos.org, which only advances a channel pointer once Hydra has
#   finished that jobset and pushed the results to cache.nixos.org. `nixos-26.05`
#   is that channel; the plain `release-26.05` git branch has no channel and
#   therefore no such guarantee, and advances ahead of what has been built;
# - cache.nixos.org, which is queried for the exact store paths this flake
#   evaluates to. A path with no substitute there is a path nix compiles.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

dotfiles_test_parse_args "$@"

# The flake output name. bootstrap.sh and rebuild.sh name the same one.
CONFIG=pc

# GET a URL, printing the body, and return non-zero on any non-2xx status.
fetch() { curl -sfL --max-time 30 "$1"; }

# True when cache.nixos.org can serve a prebuilt copy of a /nix/store path.
has_substitute() {
  local hash
  hash=$(basename "$1" | cut -d- -f1)
  [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 \
        "https://cache.nixos.org/$hash.narinfo")" = 200 ]
}

# --- the tracked ref must be a real, Hydra-verified channel -------------------
#
# flake.lock is the pinned, machine-consumed artifact that records which ref
# `nix flake update` follows, so it is parsed as JSON rather than scanned. What
# the check asserts is external: that channels.nixos.org publishes a revision
# for that ref.

test_nixpkgs_input_tracks_a_published_channel() {
  local ref rev
  if ! command -v python3 >/dev/null 2>&1; then
    skip "nixpkgs channel check (python3 not found)"
    return 0
  fi
  if ! fetch https://channels.nixos.org/ >/dev/null 2>&1; then
    skip "nixpkgs channel check (channels.nixos.org unreachable)"
    return 0
  fi

  ref=$(python3 -c '
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    lock = json.load(handle)
nixpkgs = lock["nodes"][lock["nodes"]["root"]["inputs"]["nixpkgs"]]
ref = nixpkgs.get("original", {}).get("ref")
if not ref:
    sys.exit("flake.lock pins no nixpkgs ref")
sys.stdout.write(ref)
' "$ROOT/flake.lock") || fail "could not read the tracked nixpkgs ref from flake.lock"

  rev=$(fetch "https://channels.nixos.org/$ref/git-revision") \
    || fail "nixpkgs tracks '$ref', which publishes no channel revision: a rebuild can land on a commit Hydra has not built, and nix falls back to compiling locally"

  case $rev in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*)
      : ;;
    *) fail "channel '$ref' did not publish a commit revision (got: $rev)" ;;
  esac

  pass "nixpkgs: tracked ref '$ref' is a published channel (cache-verified at $rev)"
}

# --- everything nixpkgs supplies must come prebuilt ---------------------------
#
# The point of tracking a channel rather than a release branch is that a rebuild
# fetches instead of compiles. This evaluates the flake down to the store paths
# the configuration installs for its user, keeps the ones nixpkgs defines (Home
# Manager's own generated derivations are config-local and are never in any
# cache), and asks cache.nixos.org for each.
#
# The evaluated paths are for x86_64-linux whatever machine runs this, so the
# answer is about the machine the config is for, not the one asking.

test_nixpkgs_supplied_packages_are_all_prebuilt() {
  local report path missing=0 count=0 unfree
  if ! command -v nix >/dev/null 2>&1; then
    skip "binary cache coverage of the installed packages (nix not found)"
    return 0
  fi
  # Nix is present, but this repo needs the flakes and nix-command features that
  # a stock nix.conf still gates. Probe for them separately, so a machine that
  # cannot evaluate flakes at all reports `skip -` rather than blaming the
  # configuration for its own inability to read it.
  if ! nix flake metadata --no-write-lock-file "$ROOT" >/dev/null 2>&1; then
    skip "binary cache coverage of the installed packages (this nix cannot read a flake - nix-command and flakes not enabled?)"
    return 0
  fi
  if ! curl -sf --max-time 30 -o /dev/null https://cache.nixos.org/nix-cache-info; then
    skip "binary cache coverage of the installed packages (cache.nixos.org unreachable)"
    return 0
  fi

  # meta.position points at the file that defines a package, so a prefix of the
  # nixpkgs source tree is what identifies a package as coming from nixpkgs.
  # fonts.packages is included alongside home.packages because this config
  # declares the Nerd Font at system level; both are things this repo chose to
  # install, and both would be compiled locally if the cache did not have them.
  #
  # Unfree packages are separated out rather than dropped. Hydra does not build
  # what nixpkgs marks unfree, so cache.nixos.org never has one and asking for
  # it would fail this check forever, for a reason that has nothing to do with
  # the channel. They are named in the result instead, so the exclusion is
  # visible rather than silent.
  #
  # Single-quoted on purpose: the ${...} below are Nix string interpolations,
  # evaluated by nix, and the shell must not touch them.
  # shellcheck disable=SC2016
  report=$(nix eval --raw --no-write-lock-file --apply 'cfg:
    let
      src = toString cfg.pkgs.path;
      installed = cfg.config.fonts.packages ++ builtins.concatMap (u: u.home.packages)
        (builtins.attrValues cfg.config.home-manager.users);
      fromNixpkgs = builtins.filter
        (p: builtins.substring 0 (builtins.stringLength src) (p.meta.position or "") == src)
        installed;
      line = p:
        if (p.meta.unfree or false)
        then "unfree\t${p.name}"
        else "cached\t${p.outPath}";
    in builtins.concatStringsSep "\n" (map line fromNixpkgs)' \
    "$ROOT#nixosConfigurations.$CONFIG" 2>/dev/null) \
    || fail "could not evaluate the installed package set from the flake"
  [ -n "$report" ] || fail "the flake evaluated no nixpkgs-supplied packages"

  for path in $(printf '%s\n' "$report" | sed -n 's/^cached'$'\t''//p'); do
    count=$((count + 1))
    if ! has_substitute "$path"; then
      printf 'no substitute: %s\n' "$path" >&2
      missing=$((missing + 1))
    fi
  done
  [ "$count" -gt 0 ] || fail "the flake evaluated no cacheable nixpkgs packages to check"

  [ "$missing" -eq 0 ] \
    || fail "$missing of $count nixpkgs packages have no prebuilt substitute, so ./rebuild.sh would compile them locally"

  unfree=$(printf '%s\n' "$report" | sed -n 's/^unfree'$'\t''//p' | tr '\n' ' ')
  pass "nixpkgs: all $count cacheable nixpkgs packages are prebuilt${unfree:+ (built locally, unfree: ${unfree% })}"
}

test_nixpkgs_input_tracks_a_published_channel
test_nixpkgs_supplied_packages_are_all_prebuilt

test_summary 2
