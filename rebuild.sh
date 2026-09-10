#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# shellcheck source=lib/dotfiles-link.sh
. "$DIR/lib/dotfiles-link.sh"
# shellcheck source=lib/git-identity.sh
. "$DIR/lib/git-identity.sh"

# The flake output name; see bootstrap.sh for why it does not follow the machine
# name.
CONFIG=pc

# Refuse before sudo, not after: the switch below builds ~/.dotfiles#pc.
dotfiles_link_apply "$DIR"

# Not `exec sudo`: the identity report below has to run after the switch, which
# is what installs home.nix's include of ~/.gitconfig.local. bootstrap.sh runs
# once and never prompts again, so a machine set up before the identity left the
# tracked config would otherwise lose it here without a word. The switch's own
# exit status is kept and re-raised, so a report can neither fail a good rebuild
# nor hide a failed one.
STATUS=0
sudo nixos-rebuild switch --flake "$HOME/.dotfiles#$CONFIG" || STATUS=$?

# `missing-only`: this runs on every single switch, so it speaks only about a
# key git resolves to nothing and would guess. An identity deliberately kept in
# another file is a correct setup, and bootstrap.sh already said so once.
git_identity_report missing-only

exit "$STATUS"
