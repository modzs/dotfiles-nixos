#!/usr/bin/env bash
# lib/git-identity.sh - the single definition of "what identity does git report
# on this machine, and where does it come from".
#
# Sourced by bootstrap.sh and rebuild.sh, which ask the same question at two
# different moments: bootstrap.sh once, right after the first switch, and
# rebuild.sh after every later one. The answer is only final after the switch,
# because the switch is what installs home.nix's `programs.git.includes` entry
# for ~/.gitconfig.local. Keeping the logic here means the two callers cannot
# drift apart, for the same reason lib/dotfiles-link.sh exists.
#
# The two moments deserve different amounts of speech, so the mode is the first
# argument to `git_identity_report`:
#   full          bootstrap.sh. Speaks about a whole identity that resolves
#                 from some file other than ~/.gitconfig.local too. It runs
#                 once, right after a machine was set up, and that is the one
#                 moment where knowing which file decides is worth the reader's
#                 attention.
#   missing-only  rebuild.sh. Speaks only when git resolves one of the two keys
#                 to nothing and would therefore guess it. An identity kept
#                 deliberately in ~/.gitconfig or in a work `includeIf` is a
#                 correct setup, and rebuild.sh runs on every switch: a warning
#                 that prints forever is one nobody reads.
#
# What this must never do, each rule paid for once already:
#   - state or imply a rule about how git ranks config files. It reports the
#     value and the file git itself named, and stops there;
#   - compose a `name <email>` line out of partial data. An empty half inside a
#     full identity line reads as a whole identity that happens to look odd;
#   - suggest a remedy that only works if the reader assumes a precedence rule,
#     or one that could leave the machine with no identity at all. Setting a key
#     is only ever proposed for a key nothing on the machine sets;
#   - write anything. It reads git's answer and reports it;
#   - turn a config git could not read into a claim that nothing sets the key.
#     That state gets git's own complaint and no remedy, since no remedy runs
#     until the file git names is repaired.

# Ask git what it resolves $1 to, and from where. Sets, for the caller to read
# immediately: GIT_IDENTITY_UNREADABLE, GIT_IDENTITY_ERROR, GIT_IDENTITY_VALUE
# and GIT_IDENTITY_ORIGIN.
#
# git exits 1 for a key nothing sets, and 128 when it cannot read the config at
# all - an unparsable file it was told to include, say. Both print nothing on
# stdout, and they describe two very different machines: only the first one
# means the key is unset. So the status is kept, and anything but 0 or 1 sets
# GIT_IDENTITY_UNREADABLE with git's own complaint in GIT_IDENTITY_ERROR,
# leaving value and origin empty - in that state git has told us nothing about
# the key, and saying it is unset would be an invention.
#
# GIT_IDENTITY_ORIGIN is otherwise empty exactly when nothing on this machine
# sets the key; a key some file sets to an empty string has an origin and an
# empty value, and those are two different states. A non-file origin - git's own
# command line, a blob - is reported verbatim, since it is still what git
# answered.
#
# Asked from $HOME rather than the current directory, so the config of whatever
# repository the script happens to sit in is not read as a machine-wide one.
git_identity_lookup() {
  local key=$1 resolved status=0
  GIT_IDENTITY_VALUE=""
  GIT_IDENTITY_ORIGIN=""
  GIT_IDENTITY_UNREADABLE=""
  GIT_IDENTITY_ERROR=""
  resolved="$(git -C "$HOME" config --show-origin --get "$key" 2>/dev/null)" || status=$?
  if [ "$status" != 0 ] && [ "$status" != 1 ]; then
    GIT_IDENTITY_UNREADABLE=yes
    GIT_IDENTITY_ERROR="$(git -C "$HOME" config --show-origin --get "$key" 2>&1 >/dev/null || true)"
    return 0
  fi
  [ -n "$resolved" ] || return 0
  # `--show-origin` prints "<origin><TAB><value>". A value may itself contain a
  # tab, so split on the first one only.
  GIT_IDENTITY_ORIGIN="${resolved%%$'\t'*}"
  GIT_IDENTITY_VALUE="${resolved#*$'\t'}"
  case $GIT_IDENTITY_ORIGIN in
    file:*) GIT_IDENTITY_ORIGIN="${GIT_IDENTITY_ORIGIN#file:}" ;;
  esac
}

# Report what git resolves, or say nothing at all. Silence on a machine that
# needs no interruption is the point; see the mode table at the top of the file
# for what each caller considers worth saying.
#
# $1 is the mode, `full` or `missing-only`. $2 is an optional indent, so
# bootstrap.sh's step margin is preserved.
git_identity_report() {
  local mode=$1 indent=${2:-}
  local managed="$HOME/.gitconfig.local"
  local name_value name_origin email_value email_origin
  local unusable="" foreign=""

  git_identity_lookup user.name
  if [ -n "$GIT_IDENTITY_UNREADABLE" ]; then
    git_identity_say "$indent" "Heads up: git cannot read this machine's config, so it answers nothing"
    git_identity_say "$indent" "about your identity. Its own complaint:"
    git_identity_quote "$indent" "$GIT_IDENTITY_ERROR"
    return 0
  fi
  name_value=$GIT_IDENTITY_VALUE
  name_origin=$GIT_IDENTITY_ORIGIN
  git_identity_lookup user.email
  email_value=$GIT_IDENTITY_VALUE
  email_origin=$GIT_IDENTITY_ORIGIN

  # An empty value is as unusable to git as an unset key: it has nothing to
  # stamp the next commit with either way.
  [ -n "$name_value" ] && [ -n "$email_value" ] || unusable=yes
  [ "$name_origin" = "$managed" ] && [ "$email_origin" = "$managed" ] || foreign=yes

  if [ "$mode" = full ]; then
    [ -n "$unusable" ] || [ -n "$foreign" ] || return 0
  else
    [ -n "$unusable" ] || return 0
  fi

  # Each header states only what was actually found. A key some file sets to an
  # empty string still resolves from that file, so it is neither "no identity at
  # all" nor "not from ~/.gitconfig.local", and saying either would contradict
  # the per-key lines printed directly beneath.
  if [ -z "$name_origin" ] && [ -z "$email_origin" ]; then
    git_identity_say "$indent" "Heads up: git resolves no user.name and no user.email here, so it"
    git_identity_say "$indent" "will invent an identity for whatever you commit next."
  elif [ -n "$unusable" ]; then
    git_identity_say "$indent" "Heads up: git does not resolve a whole identity here."
  else
    git_identity_say "$indent" "Heads up: git does not resolve your whole identity from ~/.gitconfig.local,"
    git_identity_say "$indent" "the one file this setup writes."
  fi

  git_identity_report_key "$indent" user.name "$name_value" "$name_origin"
  git_identity_report_key "$indent" user.email "$email_value" "$email_origin"

  # Proposed only for a key nothing on this machine sets, so the advice cannot
  # depend on which file would win, and cannot end up removing the only
  # identity the machine has.
  if [ -z "$name_origin" ] || [ -z "$email_origin" ]; then
    git_identity_say "$indent" "Set what git resolves to nothing with:"
    [ -n "$name_origin" ] \
      || git_identity_say "$indent" "  git config --file ~/.gitconfig.local user.name \"Your Name\""
    [ -n "$email_origin" ] \
      || git_identity_say "$indent" "  git config --file ~/.gitconfig.local user.email \"you@example.com\""
  fi
}

# One observation line per key: the value git resolved and the origin git named,
# or the plain fact that nothing on the machine sets it. Each key on its own
# line, never assembled into an identity string.
git_identity_report_key() {
  local indent=$1 key=$2 value=$3 origin=$4
  if [ -z "$origin" ]; then
    git_identity_say "$indent" "  git resolves no $key."
  else
    git_identity_say "$indent" "  git resolves $key to \"$value\", from $origin."
  fi
}

# Repeat git's own words, indented under the line that introduced them: git's
# complaints run to several lines, and each has to stay inside the report's
# margin.
git_identity_quote() {
  local indent=$1 text=$2 line
  [ -n "$text" ] || return 0
  while IFS= read -r line; do
    git_identity_say "$indent" "  $line"
  done <<< "$text"
}

# printf, not echo: an identity value is arbitrary text, and echo would eat a
# leading -n or -e.
git_identity_say() {
  printf '%s%s\n' "$1" "$2"
}
