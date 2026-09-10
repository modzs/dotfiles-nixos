#!/usr/bin/env bash
# lib/npm-globals.sh - install the pinned agent CLIs that are not in nixpkgs.
#
# Called by `home.activation.agentNpmCLIs` in home.nix on every switch. It is a
# file rather than a Nix string inlined there so that a test can execute it: it
# is the most intricate logic in the repo and the one step that runs on every
# single rebuild, and an inline activation string cannot be run by anything but
# a switch.
#
#   npm-globals.sh <node-bin-dir> <npm-prefix> <name@version>...
#
# The pinned versions are arguments, never baked in here: `npmGlobals` in
# home.nix stays the single source of truth for what is pinned.
#
# Contract, which tests/npm-globals.test.sh pins down:
#   - a spec whose installed version already matches is skipped, so a rebuild
#     with nothing to change touches the network zero times;
#   - anything else is installed at exactly the pinned version, into the given
#     prefix;
#   - a failed install warns and the script still succeeds, so a switch is
#     never aborted by an offline machine;
#   - with DRY_RUN set, it reports what it would install and installs nothing;
#   - a miswired call - a node bin directory without both binaries this needs,
#     or an npm prefix that is not an absolute path - stops the switch loudly.
#     The tolerances above exist for offline machines and corrupt manifests, and
#     would otherwise absorb a wiring bug into an "offline?" warning, or into a
#     full reinstall of every pin, on every rebuild, forever.
set -eu

if [ "$#" -lt 2 ]; then
  echo "usage: npm-globals.sh <node-bin-dir> <npm-prefix> <name@version>..." >&2
  exit 2
fi

nodeBin=$1
npmPrefix=$2
shift 2

case $npmPrefix in
  /*) : ;;
  *)
    echo "npm-globals.sh: npm prefix must be an absolute path, got '$npmPrefix'" >&2
    exit 2
    ;;
esac

for required in npm node; do
  if [ ! -x "$nodeBin/$required" ]; then
    echo "npm-globals.sh: no executable $required in node bin directory '$nodeBin'" >&2
    exit 2
  fi
done

for spec in "$@"; do
  name="${spec%@*}"
  want="${spec##*@}"
  manifest="$npmPrefix/lib/node_modules/$name/package.json"

  have=""
  if [ -r "$manifest" ]; then
    have="$("$nodeBin/node" -p "require('$manifest').version" 2>/dev/null || true)"
  fi
  if [ "$have" = "$want" ]; then
    continue
  fi

  if [ -n "${DRY_RUN+x}" ]; then
    echo "would install $spec into $npmPrefix"
    continue
  fi

  echo "installing $spec into $npmPrefix"
  if ! PATH="$nodeBin:$PATH" NPM_CONFIG_PREFIX="$npmPrefix" \
       "$nodeBin/npm" install --global --no-fund --no-audit "$spec"; then
    echo "warning: could not install $spec (offline?). Keeping ${have:-nothing}." >&2
  fi
done

exit 0
