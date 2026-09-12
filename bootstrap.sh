#!/usr/bin/env bash
# Bootstrap an already-installed NixOS machine into this configuration.
# Run this once. After it finishes, use ./rebuild.sh for every later change.
#
# This does NOT install NixOS. NixOS installs itself from its own ISO, and that
# is the one part of the path this repo does not own - see "Part 1: Install
# NixOS" in HOW-TO.md. What this script does is take the minimal system that
# install leaves behind and hand it to this flake.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# shellcheck source=lib/dotfiles-link.sh
. "$DIR/lib/dotfiles-link.sh"
# shellcheck source=lib/git-identity.sh
. "$DIR/lib/git-identity.sh"
# shellcheck source=lib/hardware-config.sh
. "$DIR/lib/hardware-config.sh"

# The flake output name. A stable config identifier, deliberately separate from
# the machine name set in step 3; if you rename it, change it in flake.nix and
# rebuild.sh too.
CONFIG=pc

# Read the single `<key> = "<value>";` line flake.nix declares, or nothing.
flake_line_value() {
  sed -nE "s/^[[:space:]]*$1 = \"([^\"]+)\";.*/\1/p" "$DIR/flake.nix" | head -n1
}

# Rewrite that line's value in place. Written beside flake.nix and moved over
# it, rather than with `sed -i`: the two spellings of that flag disagree between
# GNU and BSD sed, and the rename is atomic, so an interrupted run can never
# leave the file that names this machine's user half-written.
rewrite_flake_line() {
  local key=$1 value=$2 scratch
  scratch="$(mktemp "$DIR/flake.nix.XXXXXX")" || return 1
  if sed -E "s/^([[:space:]]*$key = \")[^\"]+(\";.*)/\1${value}\2/" \
       "$DIR/flake.nix" >"$scratch"; then
    mv "$scratch" "$DIR/flake.nix"
  else
    rm -f "$scratch"
    return 1
  fi
}

# Everything below resolves through ~/.dotfiles, so settle that path before
# anything is written and before sudo is asked for. Refusing here costs the user
# nothing; refusing at step 6 would cost them a password and a half-configured
# machine.
echo "==> Preflight: ~/.dotfiles"
# A failing command substitution in an assignment exits under `set -e`, so an
# unusable ~/.dotfiles stops the script right here.
PREFLIGHT="$(dotfiles_link_check "$DIR")"
if [ "$PREFLIGHT" = already ]; then
  echo "    this repository already is ~/.dotfiles"
else
  echo "    ok"
fi

# The other thing worth refusing before any prompt: this script drives NixOS
# tooling and git, and without one of them every step after the symlink would
# fail one at a time with a different error. git is as load-bearing as the two
# NixOS tools and absent for a different reason: step 4 writes the identity with
# `git config --file` and the report after the switch reads it back, while a
# fresh NixOS has no git at all until this configuration's first switch installs
# one. Both of those read git's exit status rather than aborting, so a missing
# binary would not stop the run - it would reach the end and describe a machine
# that was never written to.
echo "==> Preflight: the tools this script needs"
for required in nixos-rebuild nixos-generate-config git; do
  command -v "$required" >/dev/null 2>&1 && continue
  echo "    \"$required\" is not on this machine's PATH."
  case $required in
    git)
      echo "    A fresh NixOS has no git until this configuration's first switch"
      echo "    installs one, and step 4 needs it to write your identity. Run this"
      echo "    from the same \"nix-shell -p git\" you cloned with - see"
      echo "    \"Part 2: Hand the Machine to This Repo\" in HOW-TO.md."
      ;;
    *)
      echo "    This repository configures NixOS, and it expects NixOS to be"
      echo "    installed already. See \"Part 1: Install NixOS\" in HOW-TO.md."
      ;;
  esac
  exit 1
done
echo "    ok"

echo "==> Step 1: symlink this repo to ~/.dotfiles"
dotfiles_link_apply "$DIR"

echo "==> Step 2: personalize the configured username"
REAL_USER="$(whoami)"
FLAKE_USER="$(flake_line_value user)"
if [ -z "$FLAKE_USER" ]; then
  echo "    Could not find the single \"user = \" line in flake.nix."
  echo "    Edit flake.nix yourself before continuing."
  exit 1
elif [ "$FLAKE_USER" != "$REAL_USER" ]; then
  echo "    flake.nix is configured for user \"$FLAKE_USER\", but you are \"$REAL_USER\"."
  read -r -p "    Rewrite flake.nix's \"user = \" line to \"$REAL_USER\"? [y/N] " REPLY || true
  if [ "$REPLY" = "y" ] || [ "$REPLY" = "Y" ]; then
    rewrite_flake_line user "$REAL_USER"
    echo "    Updated. Review the change with: git diff flake.nix"
  else
    echo "    Skipped. Edit the single \"user = \" line in flake.nix yourself before continuing."
    exit 1
  fi
else
  echo "    flake.nix already matches \"$REAL_USER\", nothing to do."
fi

echo "==> Step 3: personalize the machine name"
CURRENT_NAME="$(hostname 2>/dev/null || cat /proc/sys/kernel/hostname)"
FLAKE_HOSTNAME="$(flake_line_value hostName)"
if [ -z "$FLAKE_HOSTNAME" ]; then
  echo "    Could not find the single \"hostName = \" line in flake.nix."
  echo "    Edit flake.nix yourself before continuing."
  exit 1
fi
echo "    This machine is currently named \"$CURRENT_NAME\"."
echo "    flake.nix is configured for \"$FLAKE_HOSTNAME\"."
read -r -p "    Machine name [$FLAKE_HOSTNAME]: " NEW_HOSTNAME || true
NEW_HOSTNAME="${NEW_HOSTNAME:-$FLAKE_HOSTNAME}"
if ! [[ "$NEW_HOSTNAME" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]; then
  echo "    \"$NEW_HOSTNAME\" is not a valid machine name."
  echo "    Use 1-63 letters, digits, or hyphens, starting and ending with a letter or digit."
  exit 1
fi
if [ "$NEW_HOSTNAME" != "$FLAKE_HOSTNAME" ]; then
  rewrite_flake_line hostName "$NEW_HOSTNAME"
  echo "    Updated flake.nix. Review the change with: git diff flake.nix"
else
  echo "    Keeping \"$FLAKE_HOSTNAME\"."
fi
echo "    NixOS will apply this during the switch in step 6."

echo "==> Step 4: personalize the git identity"
# The identity lives in the untracked ~/.gitconfig.local, never in this repo:
# home.nix sets no name or email, it only pulls that file in through
# programs.git.includes. Writing the two keys with `git config --file` leaves
# anything else already in the file - work-machine overrides, say - untouched.
GITCONFIG_LOCAL="$HOME/.gitconfig.local"

# git's complaints run to several lines. Indent every one of them, so a quoted
# error stays visibly part of the step rather than breaking out of its margin.
echo_git_output() {
  printf '%s\n' "$1" | sed 's/^/      /'
}

# One wording for the file's contents, printed before the prompts and again
# after the writes, so the two can never disagree. Each key is reported on its
# own: half an identity rendered as "name <email>" reads as a whole one.
print_gitconfig_local_state() {
  local name=$1 email=$2
  if [ -n "$name" ] && [ -n "$email" ]; then
    echo "    ~/.gitconfig.local holds user.name \"$name\" and user.email \"$email\"."
  elif [ -n "$name" ]; then
    echo "    ~/.gitconfig.local holds user.name \"$name\" and no user.email."
  elif [ -n "$email" ]; then
    echo "    ~/.gitconfig.local holds user.email \"$email\" and no user.name."
  else
    echo "    ~/.gitconfig.local holds no user.name and no user.email."
  fi
}

# A hand-edited ~/.gitconfig.local can be unparsable, and then every read of it
# comes back empty - indistinguishable from a file that simply sets nothing.
# Ask git once, keep its complaint, and report that instead of a false "holds
# nothing".
GITCONFIG_LOCAL_ERROR=""
if [ -e "$GITCONFIG_LOCAL" ]; then
  GITCONFIG_LOCAL_ERROR="$(git config --file "$GITCONFIG_LOCAL" --list 2>&1 >/dev/null || true)"
fi
# Prefer what that file already says, and offer nothing otherwise: a default
# read from this machine's wider git config would propose whoever configured it
# before - including the identity this repo deliberately stopped shipping.
GIT_NAME="$(git config --file "$GITCONFIG_LOCAL" --get user.name 2>/dev/null || true)"
GIT_EMAIL="$(git config --file "$GITCONFIG_LOCAL" --get user.email 2>/dev/null || true)"
echo "    This step writes a git name and email to ~/.gitconfig.local, which"
echo "    lives outside this repo and is never committed."
if [ -n "$GITCONFIG_LOCAL_ERROR" ]; then
  echo "    git cannot parse ~/.gitconfig.local, so nothing can be read from it:"
  echo_git_output "$GITCONFIG_LOCAL_ERROR"
  echo "    Fix that file by hand; the steps below run either way."
else
  print_gitconfig_local_state "$GIT_NAME" "$GIT_EMAIL"
fi
read -r -p "    Git name [$GIT_NAME]: " NEW_GIT_NAME || true
NEW_GIT_NAME="${NEW_GIT_NAME:-$GIT_NAME}"
# Whatever is typed is taken as given. flake.nix is already rewritten by now, so
# no answer may abort the run, and git validates neither key itself. An empty
# answer is a deliberate skip: home.nix's include handles an absent
# ~/.gitconfig.local.
read -r -p "    Git email [$GIT_EMAIL]: " NEW_GIT_EMAIL || true
NEW_GIT_EMAIL="${NEW_GIT_EMAIL:-$GIT_EMAIL}"
# Each key is written and reported on its own: a name typed without an email is
# still the user's answer, and one key git refuses says nothing about the other.
# A write git refuses - an unparsable file, or a duplicated [user] section it
# cannot collapse - carries git's own reason and is survived, never allowed to
# kill the run one step short of the switch.
WROTE=""
UNWRITABLE=""
write_identity_key() {
  local key=$1 value=$2 err status=0
  [ -n "$value" ] || return 0
  err="$(git config --file "$GITCONFIG_LOCAL" "$key" "$value" 2>&1 >/dev/null)" || status=$?
  if [ "$status" = 0 ]; then
    WROTE=yes
    echo "    Wrote $key to ~/.gitconfig.local."
    return 0
  fi
  UNWRITABLE=yes
  echo "    git refused to write $key to ~/.gitconfig.local:"
  [ -z "$err" ] || echo_git_output "$err"
  echo "    Repair that file by hand, then set that key with:"
  echo "      git config --file ~/.gitconfig.local $key \"$value\""
}
write_identity_key user.name "$NEW_GIT_NAME"
write_identity_key user.email "$NEW_GIT_EMAIL"
# Report the file, not the keystrokes. A prompt answered with Enter leaves
# whatever was already there, so only a fresh read says what the file holds now.
FINAL_GIT_NAME="$(git config --file "$GITCONFIG_LOCAL" --get user.name 2>/dev/null || true)"
FINAL_GIT_EMAIL="$(git config --file "$GITCONFIG_LOCAL" --get user.email 2>/dev/null || true)"
# What is still missing is left to the post-switch report below. That is the
# only moment the answer is final, and advice given before it is the defect this
# whole arrangement exists to remove.
if [ -z "$GITCONFIG_LOCAL_ERROR" ] && [ -z "$UNWRITABLE" ] && [ -n "$WROTE" ]; then
  print_gitconfig_local_state "$FINAL_GIT_NAME" "$FINAL_GIT_EMAIL"
fi

echo "==> Step 5: describe this machine's real hardware"
# The tracked hardware-configuration.nix is a placeholder that exists so the
# flake evaluates before any machine does. This is where it stops being a
# placeholder. Everything above this line was free; this is the first step that
# asks for a password, and the last one before the switch.
hardware_config_apply "$DIR/hardware-configuration.nix" "    "

echo "==> Step 6: first build and switch"
# No bootstrapping dance is needed here, unlike on a fresh macOS: NixOS ships
# nixos-rebuild, and the preflight above already refused a machine without it.
# `sudo` finds it because NixOS sets no secure_path at all - its sudo is built
# without --with-secure-path and the generated sudoers declares no Defaults for
# it - so sudo keeps this shell's PATH, which carries /run/current-system/sw/bin
# from environment.profiles. See AGENTS.md for why there is no guard here.
sudo nixos-rebuild switch --flake "$HOME/.dotfiles#$CONFIG"

# Only now is the answer final: the switch is what installs home.nix's include
# of ~/.gitconfig.local, so before it git could not have read the file step 4
# just wrote. Asked any earlier, this reported a conflict that the switch itself
# then resolved. It stays silent unless something is worth saying.
#
# `full`: this is the one run that also names the file behind an identity that
# resolves from somewhere other than ~/.gitconfig.local. rebuild.sh would say
# that on every switch forever, so it does not.
git_identity_report full "    "

echo "==> Done. Log out and back in to land in the configured session."
echo "    Use ./rebuild.sh for future changes."
