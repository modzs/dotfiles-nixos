#!/usr/bin/env bash
# Behaviour tests for bootstrap.sh and rebuild.sh.
#
# Every case runs the real, unmodified scripts against a sandboxed $HOME inside
# a temp directory, with PATH shims for sudo, nixos-rebuild, nixos-generate-config
# and hostname that record their arguments instead of executing. Nothing here
# touches the real $HOME, the real ~/.dotfiles, Nix, or this machine's system
# configuration - and nothing here needs to run on NixOS, or on Linux at all.
#
# Coverage:
# - the ~/.dotfiles link: absent, a stale symlink, an already-correct symlink,
#   the repo cloned to ~/.dotfiles itself, an unrelated real directory, and a
#   real file - for both bootstrap.sh and rebuild.sh;
# - the personalization matrix: username match, mismatch answered y, mismatch
#   answered n, a valid machine name, an invalid machine name, and empty input
#   keeping the configured default;
# - the git identity prompt: a new identity written to ~/.gitconfig.local, empty
#   input keeping the identity already there, a name typed without an email, a
#   malformed email taken as typed instead of aborting, a file holding only one
#   of the two keys, no default offered from the wider git config, an existing
#   ~/.gitconfig.local keeping its unrelated contents, a ~/.gitconfig setting a
#   key the new identity also sets, an unparsable ~/.gitconfig.local that must
#   not abort the run, and a write git refuses for one key but not the other;
# - the identity report both scripts make after the switch: silence when both
#   keys resolve from ~/.gitconfig.local, no identity at all, only one of the
#   two keys resolving, a key set to an empty value in ~/.gitconfig and in
#   ~/.gitconfig.local, a config git cannot read at all, an identity an
#   overriding file decides - which bootstrap.sh names and rebuild.sh keeps
#   quiet about - and a failing switch whose exit status must survive the
#   report;
# - the hardware seam in step 5: the tracked placeholder replaced by what
#   nixos-generate-config prints, and a generator failure stopping the run
#   before the switch rather than after it;
# - the preflight for a machine missing a tool the script cannot do without -
#   the NixOS tooling, and git: refused before any prompt and before anything is
#   written, and silent on a machine that has all three.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

dotfiles_test_parse_args "$@"

TMP_ROOT=$(dotfiles_test_tmproot dotfiles-bootstrap)

# --- sandbox -----------------------------------------------------------------

# Build a disposable sandbox and echo its root. Layout:
#   <sb>/home            the fake $HOME
#   <sb>/repo            a copy of the working tree (the default repo location)
#   <sb>/bin             sudo / nixos-rebuild / nixos-generate-config / hostname shims
#   <sb>/calls.log       every shim invocation, in order
# $1 (optional) is the path the repo copy should live at, relative to <sb>.
make_sandbox() {
  local repo_rel=${1:-repo} sb
  # mktemp, not a counter: make_sandbox is called inside a command
  # substitution, so any variable it increments would only change in the
  # subshell and every case would collide on the same directory.
  sb=$(mktemp -d "$TMP_ROOT/case.XXXXXX") || fail "could not create a sandbox"
  # Never build a sandbox at a path we did not just create: an empty $sb would
  # turn every path below into an absolute one and write to the real root.
  case $sb in
    "$TMP_ROOT"/*) [ -d "$sb" ] || fail "sandbox $sb was not created" ;;
    *) fail "sandbox path escaped the test temp root: '$sb'" ;;
  esac
  mkdir -p "$sb/home" "$sb/bin" "$sb/$repo_rel"

  # Copy the working tree, not a git clone: these tests must exercise the
  # scripts as they are right now, including uncommitted edits.
  ( cd "$ROOT" && tar -cf - --exclude ./.git --exclude ./.no-mistakes . ) \
    | ( cd "$sb/$repo_rel" && tar -xf - )

  # The link and machine-name cases are not about the username, and whoever
  # runs the suite is usually not the user flake.nix declares - CI least of
  # all. Normalize it so those cases reach the step they are actually testing;
  # the username cases set it back to whatever they need.
  set_flake_line "$sb/$repo_rel/flake.nix" user "$(whoami)"

  # The switch is also where the git identity becomes readable: NixOS applies
  # home.nix's programs.git through the Home Manager module, and that file's
  # `include` is the only thing that pulls ~/.gitconfig.local into git's view.
  # Reproduce exactly that part here, so the post-switch report sees what it
  # would see on a real machine and not an identity no include had reached yet.
  #
  # The same shim answers the other thing bootstrap.sh runs under sudo:
  # `nixos-generate-config --show-hardware-config`, which prints a machine's
  # real hardware description on stdout. A <sb>/hardware-exit file makes that
  # print nothing and fail, for the case about a generator this repo cannot fix.
  # A <sb>/sudo-exit file makes the switch fail with that status, for the cases
  # about what a failing rebuild reports.
  cat >"$sb/bin/sudo" <<SHIM
#!/bin/sh
echo "sudo \$*" >>"$sb/calls.log"
case "\$*" in
  *nixos-generate-config*)
    if [ -f "$sb/hardware-exit" ]; then
      echo "this machine could not be inspected" >&2
      exit "\$(cat "$sb/hardware-exit")"
    fi
    cat "$sb/hardware-fixture"
    exit 0
    ;;
  *"switch --flake"*)
    mkdir -p "\$HOME/.config/git"
    if ! grep -q 'gitconfig\.local' "\$HOME/.config/git/config" 2>/dev/null; then
      printf '[include]\n\tpath = ~/.gitconfig.local\n' >>"\$HOME/.config/git/config"
    fi
    ;;
esac
if [ -f "$sb/sudo-exit" ]; then
  exit "\$(cat "$sb/sudo-exit")"
fi
exit 0
SHIM

  # What the sudo shim prints for nixos-generate-config. Only the root
  # filesystem line matters to lib/hardware-config.sh; the rest is here so the
  # fixture reads like the real output.
  cat >"$sb/hardware-fixture" <<'HWEOF'
# Do not modify this file!  It was generated by 'nixos-generate-config'
{ config, lib, pkgs, modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];
  boot.initrd.availableKernelModules = [ "nvme" "xhci_pci" ];
  boot.kernelModules = [ "kvm-amd" ];
  fileSystems."/" = { device = "/dev/disk/by-uuid/deadbeef"; fsType = "ext4"; };
  swapDevices = [ ];
}
HWEOF

  # bootstrap.sh's preflight only asks whether these exist; the sudo shim above
  # is what actually answers for them. A case that removes them is testing the
  # machine the preflight is about: one that is not NixOS.
  cat >"$sb/bin/nixos-rebuild" <<SHIM
#!/bin/sh
echo "nixos-rebuild \$*" >>"$sb/calls.log"
exit 0
SHIM
  cat >"$sb/bin/nixos-generate-config" <<SHIM
#!/bin/sh
echo "nixos-generate-config \$*" >>"$sb/calls.log"
exit 0
SHIM
  # Pinned, so the machine-name step reports the same current name everywhere -
  # the runner's own hostname would otherwise leak into the expected output.
  cat >"$sb/bin/hostname" <<SHIM
#!/bin/sh
echo "hostname \$*" >>"$sb/calls.log"
echo sandbox-pc
exit 0
SHIM
  chmod +x "$sb/bin/sudo" "$sb/bin/nixos-rebuild" \
    "$sb/bin/nixos-generate-config" "$sb/bin/hostname"

  printf '%s\n' "$sb"
}

# Run one of the repo's scripts inside a sandbox.
#   $1 sandbox root, $2 script path relative to the repo copy,
#   $3 repo path relative to the sandbox, $4 stdin to feed,
#   $5 (optional) the PATH to run with, defaulting to the shims plus our own
# Writes combined output to <sb>/out and echoes the exit status.
run_script() {
  local sb=$1 script=$2 repo_rel=$3 input=$4 status=0
  local path=${5:-}
  [ -n "$path" ] || path="$sb/bin:$PATH"
  # Belt and braces: never run with anything but the sandbox as $HOME.
  case "$sb/home" in
    "$TMP_ROOT"/*) : ;;
    *) fail "refusing to run with \$HOME outside the test temp root" ;;
  esac
  # git reads /etc/gitconfig and $XDG_CONFIG_HOME/git/config as well as $HOME,
  # so pin both into the sandbox: an identity on the runner's own machine must
  # never decide what these cases observe.
  printf '%s' "$input" \
    | env HOME="$sb/home" PATH="$path" \
        GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$sb/home/.config" \
        "$BASH" "$sb/$repo_rel/$script" \
      >"$sb/out" 2>&1 || status=$?
  printf '%s\n' "$status"
}

run_bootstrap() {
  run_script "$1" bootstrap.sh "${2:-repo}" "${3:-$'\n'}" "${4:-}"
}

sandbox_out() { cat "$1/out"; }
sandbox_calls() { cat "$1/calls.log" 2>/dev/null || true; }

# Rewrite the single `<key> = "<value>";` line in a flake.nix fixture. Written
# through a temp file rather than with `sed -i`, whose spelling differs between
# GNU and BSD sed: this suite must run wherever the repository is edited, not
# only on the Linux it configures.
set_flake_line() {
  local file=$1 key=$2 value=$3 scratch
  scratch="$file.rewrite"
  sed -E "s/^([[:space:]]*$key = \")[^\"]+(\";.*)/\1${value}\2/" "$file" >"$scratch" \
    || fail "could not rewrite the $key line in $file"
  mv "$scratch" "$file"
}

# --- the ~/.dotfiles link (finding H1) ---------------------------------------

test_link_created_when_absent() {
  local sb status
  sb=$(make_sandbox)
  status=$(run_bootstrap "$sb")

  [ "$status" = 0 ] || fail "bootstrap failed with an absent ~/.dotfiles: $(sandbox_out "$sb")"
  [ -L "$sb/home/.dotfiles" ] || fail "bootstrap did not create ~/.dotfiles as a symlink"
  [ "$(cd "$sb/home/.dotfiles" && pwd -P)" = "$(cd "$sb/repo" && pwd -P)" ] \
    || fail "the ~/.dotfiles link does not resolve to the repo"
  # bootstrap.sh writes `--flake "$HOME/.dotfiles#pc"`, which the shell expands
  # to the sandbox $HOME before the shim ever sees it.
  assert_contains "$(sandbox_calls "$sb")" "switch --flake $sb/home/.dotfiles#pc" \
    "bootstrap did not reach the switch"

  pass "link: an absent ~/.dotfiles becomes a symlink to the repo"
}

test_link_rerun_is_idempotent() {
  local sb status
  sb=$(make_sandbox)
  status=$(run_bootstrap "$sb")
  [ "$status" = 0 ] || fail "first bootstrap run failed: $(sandbox_out "$sb")"
  status=$(run_bootstrap "$sb")

  [ "$status" = 0 ] || fail "second bootstrap run failed: $(sandbox_out "$sb")"
  [ -L "$sb/home/.dotfiles" ] || fail "the ~/.dotfiles link stopped being a symlink on re-run"
  [ "$(cd "$sb/home/.dotfiles" && pwd -P)" = "$(cd "$sb/repo" && pwd -P)" ] \
    || fail "the ~/.dotfiles link no longer resolves to the repo after a re-run"

  pass "link: an already-correct ~/.dotfiles symlink survives a re-run unchanged"
}

test_link_replaces_stale_symlink() {
  local sb status
  sb=$(make_sandbox)
  mkdir -p "$sb/somewhere-else"
  ln -sfn "$sb/somewhere-else" "$sb/home/.dotfiles"
  status=$(run_bootstrap "$sb")

  [ "$status" = 0 ] || fail "bootstrap failed against a stale symlink: $(sandbox_out "$sb")"
  [ "$(cd "$sb/home/.dotfiles" && pwd -P)" = "$(cd "$sb/repo" && pwd -P)" ] \
    || fail "a stale ~/.dotfiles symlink was not repointed at the repo"

  pass "link: a stale ~/.dotfiles symlink is repointed at the repo"
}

# The regression that matters most: cloning to ~/.dotfiles is the most natural
# install and the path both documents tell you to cd into. The old
# `ln -sfn "$DIR" ~/.dotfiles` exited 0 while planting ~/.dotfiles/dotfiles ->
# ~/.dotfiles, a self-referential symlink inside the user's own git tree.
test_link_when_repo_already_is_dotfiles() {
  local sb status
  sb=$(make_sandbox home/.dotfiles)
  status=$(run_bootstrap "$sb" home/.dotfiles)

  [ "$status" = 0 ] || fail "bootstrap failed when the repo is ~/.dotfiles: $(sandbox_out "$sb")"
  [ -d "$sb/home/.dotfiles" ] && [ ! -L "$sb/home/.dotfiles" ] \
    || fail "bootstrap turned the repo at ~/.dotfiles into a symlink"
  [ -z "$(find "$sb/home/.dotfiles" -maxdepth 1 -type l)" ] \
    || fail "bootstrap planted a symlink inside the repo at ~/.dotfiles"
  assert_contains "$(sandbox_out "$sb")" "already is ~/.dotfiles" \
    "bootstrap did not report that the repo already is ~/.dotfiles"
  assert_contains "$(sandbox_calls "$sb")" "switch --flake $sb/home/.dotfiles#pc" \
    "bootstrap did not reach the switch when the repo is ~/.dotfiles"

  pass "link: a repo cloned to ~/.dotfiles needs no link and bootstrap continues"
}

# The other half of H1: a pre-existing, unrelated ~/.dotfiles used to be
# accepted silently, and bootstrap died at the switch - after taking the user's
# sudo password - with "could not find a flake.nix file".
test_link_refuses_unrelated_directory() {
  local sb status
  sb=$(make_sandbox)
  mkdir -p "$sb/home/.dotfiles/somethingelse"
  status=$(run_bootstrap "$sb")

  [ "$status" != 0 ] || fail "bootstrap accepted an unrelated ~/.dotfiles directory"
  assert_contains "$(sandbox_out "$sb")" "already exists and is not a symlink" \
    "bootstrap did not explain why it refused"
  assert_not_contains "$(sandbox_out "$sb")" "Step 1" \
    "bootstrap refused only after starting to change the machine"
  [ -z "$(sandbox_calls "$sb")" ] \
    || fail "bootstrap ran a privileged or external command before refusing: $(sandbox_calls "$sb")"
  [ -d "$sb/home/.dotfiles/somethingelse" ] \
    || fail "bootstrap disturbed the existing ~/.dotfiles directory"
  [ -z "$(find "$sb/home/.dotfiles" -maxdepth 1 -type l)" ] \
    || fail "bootstrap created a symlink inside the existing ~/.dotfiles directory"

  pass "link: an unrelated ~/.dotfiles directory is refused before anything is written"
}

test_link_refuses_regular_file() {
  local sb status
  sb=$(make_sandbox)
  printf 'not a directory\n' >"$sb/home/.dotfiles"
  status=$(run_bootstrap "$sb")

  [ "$status" != 0 ] || fail "bootstrap accepted a regular file at ~/.dotfiles"
  assert_contains "$(sandbox_out "$sb")" "already exists and is not a symlink" \
    "bootstrap did not explain why it refused a regular file"
  [ -z "$(sandbox_calls "$sb")" ] \
    || fail "bootstrap ran a privileged or external command before refusing"

  pass "link: a regular file at ~/.dotfiles is refused before anything is written"
}

test_rebuild_refuses_unrelated_directory() {
  local sb status
  sb=$(make_sandbox)
  mkdir -p "$sb/home/.dotfiles/somethingelse"
  status=$(run_script "$sb" rebuild.sh repo "")

  [ "$status" != 0 ] || fail "rebuild.sh accepted an unrelated ~/.dotfiles directory"
  assert_contains "$(sandbox_out "$sb")" "already exists and is not a symlink" \
    "rebuild.sh did not explain why it refused"
  [ -z "$(sandbox_calls "$sb")" ] \
    || fail "rebuild.sh reached sudo despite an unusable ~/.dotfiles"

  pass "rebuild: an unrelated ~/.dotfiles directory is refused before sudo"
}

test_rebuild_when_repo_already_is_dotfiles() {
  local sb status
  sb=$(make_sandbox home/.dotfiles)
  status=$(run_script "$sb" rebuild.sh home/.dotfiles "")

  [ "$status" = 0 ] || fail "rebuild.sh failed when the repo is ~/.dotfiles: $(sandbox_out "$sb")"
  [ -z "$(find "$sb/home/.dotfiles" -maxdepth 1 -type l)" ] \
    || fail "rebuild.sh planted a symlink inside the repo at ~/.dotfiles"
  assert_contains "$(sandbox_calls "$sb")" "sudo nixos-rebuild switch --flake $sb/home/.dotfiles#pc" \
    "rebuild.sh did not reach the switch when the repo is ~/.dotfiles"

  pass "rebuild: a repo cloned to ~/.dotfiles needs no link and the switch still runs"
}

# --- personalization ----------------------------------------------------------

flake_value() {
  sed -nE "s/^[[:space:]]*$2 = \"([^\"]+)\";.*/\1/p" "$1/repo/flake.nix" | head -n1
}

set_flake_user() {
  set_flake_line "$1/repo/flake.nix" user "$2"
}

test_username_match_leaves_flake_alone() {
  local sb status
  sb=$(make_sandbox)
  set_flake_user "$sb" "$(whoami)"
  status=$(run_bootstrap "$sb")

  [ "$status" = 0 ] || fail "bootstrap failed with a matching username: $(sandbox_out "$sb")"
  assert_contains "$(sandbox_out "$sb")" "nothing to do" \
    "bootstrap did not report the username as already correct"
  [ "$(flake_value "$sb" user)" = "$(whoami)" ] || fail "the user line changed unexpectedly"

  pass "personalize: a matching username prompts for nothing and rewrites nothing"
}

test_username_mismatch_accepted_rewrites_flake() {
  local sb status
  sb=$(make_sandbox)
  set_flake_user "$sb" someoneelse
  status=$(run_bootstrap "$sb" repo "y
"
)

  [ "$status" = 0 ] || fail "bootstrap failed after accepting the username rewrite: $(sandbox_out "$sb")"
  [ "$(flake_value "$sb" user)" = "$(whoami)" ] \
    || fail "answering y did not rewrite the user line to $(whoami)"

  pass "personalize: a username mismatch answered y rewrites the user line"
}

test_username_mismatch_declined_aborts() {
  local sb status
  sb=$(make_sandbox)
  set_flake_user "$sb" someoneelse
  status=$(run_script "$sb" bootstrap.sh repo "n
"
)

  [ "$status" != 0 ] || fail "bootstrap continued after the username rewrite was declined"
  assert_contains "$(sandbox_out "$sb")" "Edit the single \"user = \" line" \
    "bootstrap did not print the manual-edit guidance"
  [ "$(flake_value "$sb" user)" = someoneelse ] \
    || fail "answering n still rewrote the user line"
  [ -z "$(sandbox_calls "$sb")" ] || fail "bootstrap reached sudo after being declined"

  pass "personalize: a username mismatch answered n aborts without rewriting flake.nix"
}

test_machine_name_valid_is_written() {
  local sb status
  sb=$(make_sandbox)
  status=$(run_bootstrap "$sb" repo "work-laptop
"
)

  [ "$status" = 0 ] || fail "bootstrap failed with a valid machine name: $(sandbox_out "$sb")"
  [ "$(flake_value "$sb" hostName)" = work-laptop ] \
    || fail "the hostName line was not rewritten to work-laptop"

  pass "personalize: a valid machine name is written to the hostName line"
}

test_machine_name_invalid_aborts() {
  local sb status before
  sb=$(make_sandbox)
  before=$(flake_value "$sb" hostName)
  status=$(run_bootstrap "$sb" repo "bad name!
"
)

  [ "$status" != 0 ] || fail "bootstrap accepted an invalid machine name"
  assert_contains "$(sandbox_out "$sb")" "is not a valid machine name" \
    "bootstrap did not explain why the machine name was rejected"
  [ "$(flake_value "$sb" hostName)" = "$before" ] \
    || fail "an invalid machine name was written to flake.nix anyway"
  # The machine-name step legitimately calls hostname before validating, so
  # assert on sudo only.
  assert_not_contains "$(sandbox_calls "$sb")" "sudo " \
    "bootstrap reached sudo with an invalid machine name"

  pass "personalize: an invalid machine name aborts before writing anything"
}

test_machine_name_empty_keeps_default() {
  local sb status before
  sb=$(make_sandbox)
  before=$(flake_value "$sb" hostName)
  status=$(run_bootstrap "$sb")

  [ "$status" = 0 ] || fail "bootstrap failed on an empty machine name: $(sandbox_out "$sb")"
  assert_contains "$(sandbox_out "$sb")" "Keeping \"$before\"" \
    "bootstrap did not report that it kept the configured machine name"
  [ "$(flake_value "$sb" hostName)" = "$before" ] \
    || fail "empty input changed the hostName line"

  pass "personalize: empty input keeps the machine name configured in flake.nix"
}

# --- git identity (written to ~/.gitconfig.local, never to the repo) ----------

# Feed the whole prompt sequence of a run whose username already matches:
# machine name, git name, git email - each read exactly once, in that order.
identity_input() {
  local line
  for line in "$@"; do printf '%s\n' "$line"; done
}

gitconfig_local_value() {
  git config --file "$1/home/.gitconfig.local" --get "$2" 2>/dev/null || true
}

test_identity_written_to_gitconfig_local() {
  local sb status
  sb=$(make_sandbox)
  status=$(run_bootstrap "$sb" repo "$(identity_input '' 'Ada Lovelace' 'ada@example.com')")

  [ "$status" = 0 ] || fail "bootstrap failed while setting a git identity: $(sandbox_out "$sb")"
  [ "$(gitconfig_local_value "$sb" user.name)" = "Ada Lovelace" ] \
    || fail "the git name was not written to ~/.gitconfig.local"
  [ "$(gitconfig_local_value "$sb" user.email)" = "ada@example.com" ] \
    || fail "the git email was not written to ~/.gitconfig.local"
  # The whole point: the identity must never land in the tracked config, in any
  # spelling - so compare the whole file against the pristine tracked one.
  cmp -s "$sb/repo/home.nix" "$ROOT/home.nix" \
    || fail "bootstrap modified the tracked home.nix while setting the git identity"

  pass "identity: a new name and email are written to ~/.gitconfig.local"
}

test_identity_empty_keeps_existing() {
  local sb status reports
  sb=$(make_sandbox)
  git config --file "$sb/home/.gitconfig.local" user.name "Grace Hopper"
  git config --file "$sb/home/.gitconfig.local" user.email "grace@example.com"
  status=$(run_bootstrap "$sb" repo "$(identity_input '' '' '')")

  [ "$status" = 0 ] || fail "bootstrap failed on an empty git identity: $(sandbox_out "$sb")"
  # Twice by design: once from the file as found, once re-read after the writes.
  # A single occurrence means the closing report is gone, and the run would be
  # describing the keystrokes rather than the file it left behind.
  reports=$(grep -cF 'holds user.name "Grace Hopper" and user.email "grace@example.com"' \
    "$sb/out" || true)
  [ "$reports" = 2 ] \
    || fail "expected the identity reported before the prompts and again after the writes, saw $reports"
  [ "$(gitconfig_local_value "$sb" user.name)" = "Grace Hopper" ] \
    || fail "empty input changed the existing git name"
  [ "$(gitconfig_local_value "$sb" user.email)" = "grace@example.com" ] \
    || fail "empty input changed the existing git email"

  pass "identity: empty input keeps the identity already in ~/.gitconfig.local"
}

# ~/.gitconfig.local is the documented home for work-machine overrides, so the
# prompt must set two keys inside it, not rewrite the file.
test_identity_preserves_unrelated_gitconfig_local() {
  local sb status
  sb=$(make_sandbox)
  git config --file "$sb/home/.gitconfig.local" user.name "Grace Hopper"
  git config --file "$sb/home/.gitconfig.local" user.email "grace@example.com"
  git config --file "$sb/home/.gitconfig.local" core.editor "emacs"
  git config --file "$sb/home/.gitconfig.local" commit.gpgsign true
  status=$(run_bootstrap "$sb" repo "$(identity_input '' 'Ada Lovelace' 'ada@example.com')")

  [ "$status" = 0 ] || fail "bootstrap failed against an existing ~/.gitconfig.local: $(sandbox_out "$sb")"
  [ "$(gitconfig_local_value "$sb" user.email)" = "ada@example.com" ] \
    || fail "the new identity did not reach an existing ~/.gitconfig.local"
  [ "$(gitconfig_local_value "$sb" core.editor)" = emacs ] \
    || fail "bootstrap dropped an unrelated setting from ~/.gitconfig.local"
  [ "$(gitconfig_local_value "$sb" commit.gpgsign)" = true ] \
    || fail "bootstrap dropped an unrelated setting from ~/.gitconfig.local"

  pass "identity: an existing ~/.gitconfig.local keeps its unrelated settings"
}

# flake.nix is already rewritten by the time this prompt runs, so no answer may
# abort the run. git validates user.email no further than this does, so an
# odd-looking address is taken at its word rather than argued with.
test_identity_malformed_email_is_taken_as_typed() {
  local sb status
  sb=$(make_sandbox)
  status=$(run_bootstrap "$sb" repo "$(identity_input '' 'Ada Lovelace' 'not-an-email')")

  [ "$status" = 0 ] || fail "bootstrap aborted on a malformed git email: $(sandbox_out "$sb")"
  [ "$(gitconfig_local_value "$sb" user.email)" = "not-an-email" ] \
    || fail "bootstrap did not write the email exactly as it was typed"
  assert_contains "$(sandbox_calls "$sb")" "switch --flake $sb/home/.dotfiles#pc" \
    "bootstrap did not reach the switch after a malformed email"

  pass "identity: a malformed email is written as typed and never aborts the run"
}

# A value the user typed must never vanish: git itself reports the missing half
# at commit time, which beats silently discarding the half that was given.
test_identity_name_without_email_is_kept() {
  local sb status
  sb=$(make_sandbox)
  status=$(run_bootstrap "$sb" repo "$(identity_input '' 'Ada Lovelace' '')")

  [ "$status" = 0 ] || fail "bootstrap failed on a name without an email: $(sandbox_out "$sb")"
  [ "$(gitconfig_local_value "$sb" user.name)" = "Ada Lovelace" ] \
    || fail "bootstrap discarded a git name typed without an email"
  [ -z "$(gitconfig_local_value "$sb" user.email)" ] \
    || fail "bootstrap invented a git email that was never typed"
  assert_contains "$(sandbox_out "$sb")" "Wrote user.name to ~/.gitconfig.local." \
    "bootstrap did not report which identity key it wrote"
  assert_contains "$(sandbox_out "$sb")" "holds user.name \"Ada Lovelace\" and no user.email" \
    "bootstrap did not name the half ~/.gitconfig.local is missing"

  pass "identity: a name typed without an email is still written"
}


# Half an identity must never be rendered as a whole one: a file holding only an
# email once printed `commits as " <work@corp.example>"` before the prompts and
# `holds user.email ... and no user.name` after them, in the same run.
test_identity_half_set_file_is_reported_key_by_key() {
  local sb status
  sb=$(make_sandbox)
  git config --file "$sb/home/.gitconfig.local" user.email "work@corp.example"
  status=$(run_bootstrap "$sb" repo "$(identity_input '' '' '')")

  [ "$status" = 0 ] || fail "bootstrap failed on a half-set identity: $(sandbox_out "$sb")"
  assert_not_contains "$(sandbox_out "$sb")" "<work@corp.example>" \
    "bootstrap rendered a missing name inside a full identity string"
  assert_contains "$(sandbox_out "$sb")" "holds user.email \"work@corp.example\" and no user.name" \
    "bootstrap did not name the half ~/.gitconfig.local is missing"
  [ -z "$(gitconfig_local_value "$sb" user.name)" ] \
    || fail "empty input invented a git name"

  pass "identity: a file holding one key is reported key by key, not as an identity"
}

# Another config file can set the same key, one key at a time - a [user] section
# holding only an email yields a name from one file and an email from another.
# The run must name that file per key and leave it alone.
test_identity_competing_gitconfig_is_reported() {
  local sb status before
  sb=$(make_sandbox)
  cat >"$sb/home/.gitconfig" <<'GITCONFIG'
[user]
	email = previous@example.com
[credential]
	helper = libsecret
GITCONFIG
  before=$(cat "$sb/home/.gitconfig")
  status=$(run_bootstrap "$sb" repo "$(identity_input '' 'Ada Lovelace' 'ada@example.com')")

  [ "$status" = 0 ] || fail "bootstrap failed against a shadowing ~/.gitconfig: $(sandbox_out "$sb")"
  assert_contains "$(sandbox_out "$sb")" "git resolves user.email to \"previous@example.com\", from $sb/home/.gitconfig." \
    "bootstrap did not report the file git reads the email from"
  assert_contains "$(sandbox_out "$sb")" "git resolves user.name to \"Ada Lovelace\", from $sb/home/.gitconfig.local." \
    "bootstrap did not report the file git reads the name from"
  # Nothing may be proposed for a key that already resolves: which of two files
  # decides is not something this repo gets to assert, and unsetting the one
  # identity the machine has is worse than the mismatch.
  assert_not_contains "$(sandbox_out "$sb")" "git config --file ~/.gitconfig.local user.email" \
    "bootstrap prescribed a write for an email that already resolves"
  assert_not_contains "$(sandbox_out "$sb")" "--unset" \
    "bootstrap told the user to unset an identity it did not write"
  [ "$(cat "$sb/home/.gitconfig")" = "$before" ] \
    || fail "bootstrap modified ~/.gitconfig instead of only reporting it"
  [ "$(gitconfig_local_value "$sb" user.email)" = "ada@example.com" ] \
    || fail "the new email did not reach ~/.gitconfig.local"

  pass "identity: a ~/.gitconfig setting the same key is named, not edited"
}

# flake.nix is rewritten by now, so git refusing to touch a hand-broken
# ~/.gitconfig.local must cost a warning, not the whole switch.
test_identity_unparsable_gitconfig_local_still_switches() {
  local sb status
  sb=$(make_sandbox)
  printf '[user\n\tname = Broken\n' >"$sb/home/.gitconfig.local"
  status=$(run_bootstrap "$sb" repo "$(identity_input '' 'Ada Lovelace' 'ada@example.com')")

  [ "$status" = 0 ] || fail "an unparsable ~/.gitconfig.local aborted bootstrap: $(sandbox_out "$sb")"
  assert_contains "$(sandbox_calls "$sb")" "switch --flake $sb/home/.dotfiles#pc" \
    "bootstrap never reached the switch with an unparsable ~/.gitconfig.local"
  assert_contains "$(sandbox_out "$sb")" "git cannot parse ~/.gitconfig.local" \
    "bootstrap did not say the file could not be parsed"
  assert_contains "$(sandbox_out "$sb")" "git refused to write user.name to ~/.gitconfig.local" \
    "bootstrap did not report the name it could not write"
  assert_contains "$(sandbox_out "$sb")" "git refused to write user.email to ~/.gitconfig.local" \
    "bootstrap did not report the email it could not write"
  assert_not_contains "$(sandbox_out "$sb")" "holds no user.name and no user.email" \
    "bootstrap claimed an unparsable file simply holds nothing"

  pass "identity: an unparsable ~/.gitconfig.local warns and still reaches the switch"
}

# One key git refuses says nothing about the other: a duplicated [user] section
# holding two emails lets the name through and blocks the email. The run must
# report git's own reason and prescribe a remedy only for the key that failed -
# telling the user to re-set a key that just succeeded is noise at best.
test_identity_partial_write_failure_is_reported_per_key() {
  local sb status
  sb=$(make_sandbox)
  printf '[user]\n\temail = one@example.com\n[user]\n\temail = two@example.com\n' \
    >"$sb/home/.gitconfig.local"
  status=$(run_bootstrap "$sb" repo "$(identity_input '' 'Ada Lovelace' 'ada@example.com')")

  [ "$status" = 0 ] || fail "a refused write aborted bootstrap: $(sandbox_out "$sb")"
  assert_contains "$(sandbox_calls "$sb")" "switch --flake $sb/home/.dotfiles#pc" \
    "bootstrap never reached the switch after a refused write"
  [ "$(gitconfig_local_value "$sb" user.name)" = "Ada Lovelace" ] \
    || fail "the name git accepted was not written"
  assert_contains "$(sandbox_out "$sb")" "Wrote user.name to ~/.gitconfig.local." \
    "bootstrap did not report the key it did write"
  assert_contains "$(sandbox_out "$sb")" "git refused to write user.email to ~/.gitconfig.local" \
    "bootstrap did not report the key it could not write"
  assert_contains "$(sandbox_out "$sb")" "cannot overwrite multiple values" \
    "bootstrap swallowed git's reason for refusing the write"
  assert_not_contains "$(sandbox_out "$sb")" "git config --file ~/.gitconfig.local user.name" \
    "bootstrap told the user to re-set a key that had just been written"

  pass "identity: a write refused for one key leaves the other reported as written"
}

# The prompt default comes from ~/.gitconfig.local alone. Anything wider would
# re-propose whoever configured this machine before - the exact misattribution
# taking the identity out of the tracked config is meant to end.
test_identity_offers_no_default_from_global_config() {
  local sb status
  sb=$(make_sandbox)
  cat >"$sb/home/.gitconfig" <<'GITCONFIG'
[user]
	name = Previous Owner
	email = previous@example.com
GITCONFIG
  status=$(run_bootstrap "$sb" repo "$(identity_input '' '' '')")

  [ "$status" = 0 ] || fail "bootstrap failed with no ~/.gitconfig.local: $(sandbox_out "$sb")"
  # The tilde is part of the message bootstrap prints, not a path to expand.
  # shellcheck disable=SC2088
  assert_contains "$(sandbox_out "$sb")" "~/.gitconfig.local holds no user.name and no user.email" \
    "bootstrap claimed an identity that ~/.gitconfig.local does not hold"
  assert_not_contains "$(sandbox_out "$sb")" "currently commits as" \
    "bootstrap proposed an identity from outside ~/.gitconfig.local"
  # The prompt takes no default from ~/.gitconfig, but the report after the
  # switch still says what git actually resolves - which is that identity, from
  # that file. Naming it is the whole point; prescribing anything about it is
  # not, since the machine already has a working identity.
  assert_contains "$(sandbox_out "$sb")" "git resolves user.name to \"Previous Owner\", from $sb/home/.gitconfig." \
    "bootstrap did not report the identity git resolves after the switch"
  # The identity step does offer to fill in the empty ~/.gitconfig.local, which
  # is a write to this setup's own file. Removing the identity the machine
  # already has is what must never be suggested.
  assert_not_contains "$(sandbox_out "$sb")" "--unset" \
    "bootstrap told the user to unset the only identity the machine has"
  [ -z "$(gitconfig_local_value "$sb" user.name)" ] \
    || fail "empty input copied another identity into ~/.gitconfig.local"
  [ -z "$(gitconfig_local_value "$sb" user.email)" ] \
    || fail "empty input copied another identity into ~/.gitconfig.local"

  pass "identity: no default is taken from outside ~/.gitconfig.local"
}

# --- the identity report after the switch -------------------------------------
#
# Both scripts ask the same question through lib/git-identity.sh, and only after
# the switch: the switch is what installs home.nix's include of
# ~/.gitconfig.local, so any earlier answer describes a machine that no longer
# exists by the time the script ends. The sandbox's sudo shim installs that
# include, exactly as the Home Manager NixOS module would.

# Point git at an identity that does not come from ~/.gitconfig.local, the way a
# machine configured before this repo stopped shipping one still is.
write_home_gitconfig() {
  local sb=$1 name=$2 email=$3
  {
    printf '[user]\n'
    [ -z "$name" ] || printf '\tname = %s\n' "$name"
    [ -z "$email" ] || printf '\temail = %s\n' "$email"
  } >"$sb/home/.gitconfig"
}

run_rebuild() { run_script "$1" rebuild.sh "${2:-repo}" ""; }

# The silence that makes the warning worth reading: rebuild.sh runs this on
# every switch, so a correctly configured machine must hear nothing at all.
test_report_silent_when_identity_comes_from_managed_file() {
  local sb status
  sb=$(make_sandbox)
  status=$(run_bootstrap "$sb" repo "$(identity_input '' 'Ada Lovelace' 'ada@example.com')")
  [ "$status" = 0 ] || fail "bootstrap failed while setting a git identity: $(sandbox_out "$sb")"
  assert_not_contains "$(sandbox_out "$sb")" "Heads up" \
    "bootstrap warned about an identity that comes from ~/.gitconfig.local"

  status=$(run_rebuild "$sb")

  [ "$status" = 0 ] || fail "rebuild.sh failed after a good bootstrap: $(sandbox_out "$sb")"
  assert_contains "$(sandbox_calls "$sb")" "sudo nixos-rebuild switch --flake $sb/home/.dotfiles#pc" \
    "rebuild.sh did not reach the switch"
  assert_not_contains "$(sandbox_out "$sb")" "Heads up" \
    "rebuild.sh warned on a machine whose identity comes from ~/.gitconfig.local"

  pass "report: nothing is said when both keys resolve from ~/.gitconfig.local"
}

# The migration this exists for: home.nix stopped setting an identity, so a
# machine that had one from the tracked config and never re-ran bootstrap.sh
# now resolves nothing, and git guesses. rebuild.sh is the only thing that runs
# on such a machine, so it has to be what says so.
test_rebuild_reports_when_no_identity_resolves() {
  local sb status
  sb=$(make_sandbox)
  status=$(run_rebuild "$sb")

  [ "$status" = 0 ] || fail "rebuild.sh failed with no identity anywhere: $(sandbox_out "$sb")"
  assert_contains "$(sandbox_out "$sb")" "git resolves no user.name and no user.email" \
    "rebuild.sh did not report that git resolves no identity"
  # shellcheck disable=SC2088
  assert_contains "$(sandbox_out "$sb")" "git config --file ~/.gitconfig.local user.name \"Your Name\"" \
    "rebuild.sh did not say how to set the missing name"
  # shellcheck disable=SC2088
  assert_contains "$(sandbox_out "$sb")" "git config --file ~/.gitconfig.local user.email \"you@example.com\"" \
    "rebuild.sh did not say how to set the missing email"
  [ ! -e "$sb/home/.gitconfig" ] \
    || fail "rebuild.sh created ~/.gitconfig instead of only reporting"
  [ ! -e "$sb/home/.gitconfig.local" ] \
    || fail "rebuild.sh wrote an identity it was only asked to report on"

  pass "report: rebuild.sh warns when git resolves no identity at all"
}

# The case the captain hit: ~/.gitconfig.local is set up correctly and another
# file still decides. bootstrap.sh runs once, right after the machine was set
# up, so it is the moment where naming that file is worth the interruption.
# Naming the file and the value is the whole of it; this repo cannot state which
# file wins, so it prescribes nothing.
test_bootstrap_reports_identity_from_another_file() {
  local sb status before
  sb=$(make_sandbox)
  write_home_gitconfig "$sb" "Previous Owner" "previous@example.com"
  before=$(cat "$sb/home/.gitconfig")
  status=$(run_bootstrap "$sb" repo "$(identity_input '' 'Ada Lovelace' 'ada@example.com')")

  [ "$status" = 0 ] || fail "bootstrap failed against an overriding ~/.gitconfig: $(sandbox_out "$sb")"
  assert_contains "$(sandbox_out "$sb")" "git resolves user.name to \"Previous Owner\", from $sb/home/.gitconfig." \
    "bootstrap did not name the value and file git resolves the name from"
  assert_contains "$(sandbox_out "$sb")" "git resolves user.email to \"previous@example.com\", from $sb/home/.gitconfig." \
    "bootstrap did not name the value and file git resolves the email from"
  assert_not_contains "$(sandbox_out "$sb")" "--unset" \
    "bootstrap told the user to unset an identity it does not own"
  # shellcheck disable=SC2088
  assert_not_contains "$(sandbox_out "$sb")" "git config --file ~/.gitconfig.local user." \
    "bootstrap prescribed a write for keys that already resolve"
  [ "$(cat "$sb/home/.gitconfig")" = "$before" ] \
    || fail "bootstrap modified ~/.gitconfig instead of only reporting it"

  pass "report: bootstrap.sh names the file an overriding identity comes from"
}

# The same machine, one switch later. An identity deliberately kept in
# ~/.gitconfig or in a work includeIf is a correct setup, and rebuild.sh runs on
# every switch - so it says nothing here, where bootstrap.sh already spoke once.
test_rebuild_silent_when_a_whole_identity_resolves_elsewhere() {
  local sb status
  sb=$(make_sandbox)
  git config --file "$sb/home/.gitconfig.local" user.name "Ada Lovelace"
  git config --file "$sb/home/.gitconfig.local" user.email "ada@example.com"
  write_home_gitconfig "$sb" "Previous Owner" "previous@example.com"
  status=$(run_rebuild "$sb")

  [ "$status" = 0 ] || fail "rebuild.sh failed against an overriding ~/.gitconfig: $(sandbox_out "$sb")"
  assert_not_contains "$(sandbox_out "$sb")" "Heads up" \
    "rebuild.sh warned on every rebuild about an identity another file decides"

  pass "report: rebuild.sh stays quiet when a whole identity resolves from another file"
}

# A key some file sets to an empty value is not a key nothing sets: git names
# that file, so the report names it too. Calling it unset would prescribe a
# write into ~/.gitconfig.local, and this repo cannot say that would change what
# git resolves.
test_report_key_set_to_an_empty_value_names_its_file() {
  local sb status
  sb=$(make_sandbox)
  printf '[user]\n\tname = Previous Owner\n\temail = \n' >"$sb/home/.gitconfig"
  status=$(run_rebuild "$sb")

  [ "$status" = 0 ] || fail "rebuild.sh failed with an empty user.email: $(sandbox_out "$sb")"
  assert_contains "$(sandbox_out "$sb")" "git resolves user.email to \"\", from $sb/home/.gitconfig." \
    "rebuild.sh did not name the file that sets user.email to an empty value"
  assert_not_contains "$(sandbox_out "$sb")" "git resolves no user.email" \
    "rebuild.sh called a key some file sets one that nothing sets"
  # shellcheck disable=SC2088
  assert_not_contains "$(sandbox_out "$sb")" "git config --file ~/.gitconfig.local user.email" \
    "rebuild.sh prescribed a write for a key some file already sets"

  pass "report: a key set to an empty value is reported with the file that sets it"
}

# The same empty value, this time in the file this setup owns. Both keys still
# resolve from ~/.gitconfig.local, so the report may not claim the identity
# comes from somewhere else - that would contradict the two lines it prints
# directly underneath.
test_report_empty_value_in_the_managed_file_is_not_called_foreign() {
  local sb status
  sb=$(make_sandbox)
  printf '[user]\n\tname = Ada Lovelace\n\temail =\n' >"$sb/home/.gitconfig.local"
  status=$(run_rebuild "$sb")

  [ "$status" = 0 ] || fail "rebuild.sh failed with an empty user.email: $(sandbox_out "$sb")"
  assert_contains "$(sandbox_out "$sb")" "git resolves user.name to \"Ada Lovelace\", from $sb/home/.gitconfig.local." \
    "rebuild.sh did not report the name ~/.gitconfig.local sets"
  assert_contains "$(sandbox_out "$sb")" "git resolves user.email to \"\", from $sb/home/.gitconfig.local." \
    "rebuild.sh did not report the empty value ~/.gitconfig.local sets"
  # shellcheck disable=SC2088
  assert_not_contains "$(sandbox_out "$sb")" "does not resolve your whole identity from ~/.gitconfig.local" \
    "rebuild.sh denied the very file it then named for both keys"
  assert_not_contains "$(sandbox_out "$sb")" "will invent an identity" \
    "rebuild.sh claimed git would invent an identity a file already sets"

  pass "report: an empty value in ~/.gitconfig.local is not reported as coming from elsewhere"
}

# A config git refuses to parse is not a config that sets nothing: git exits 128
# with a complaint instead of 1 with silence, and every command it is given
# dies. Reporting it as "no key set" would promise an invented identity and hand
# over write commands that fail with the same parse error.
test_report_config_git_cannot_read_repeats_gits_complaint() {
  local sb status
  sb=$(make_sandbox)
  printf '[user\n\tname = Broken\n' >"$sb/home/.gitconfig.local"
  status=$(run_rebuild "$sb")

  [ "$status" = 0 ] || fail "rebuild.sh failed against an unparsable config: $(sandbox_out "$sb")"
  assert_contains "$(sandbox_out "$sb")" "git cannot read this machine's config" \
    "rebuild.sh did not say git could not read the config"
  # Nothing else rebuild.sh prints names that path, so this is git's own
  # complaint being repeated rather than a message this repo composed.
  assert_contains "$(sandbox_out "$sb")" "$sb/home/.gitconfig.local" \
    "rebuild.sh swallowed git's own complaint, which names the broken file"
  assert_not_contains "$(sandbox_out "$sb")" "will invent an identity" \
    "rebuild.sh promised an invented identity for a git that refuses to run"
  assert_not_contains "$(sandbox_out "$sb")" "git resolves no user.name" \
    "rebuild.sh reported an unreadable config as a key nothing sets"
  # shellcheck disable=SC2088
  assert_not_contains "$(sandbox_out "$sb")" "git config --file ~/.gitconfig.local user." \
    "rebuild.sh prescribed writes that fail with the same parse error"

  pass "report: a config git cannot read is reported as that, with git's own words"
}

# Half an identity is the trap: "Previous Owner <>" reads as a whole one. Each
# key is reported on its own, and only the key that resolves to nothing gets a
# remedy - the one that resolves is already someone's deliberate setting.
test_rebuild_reports_one_key_at_a_time() {
  local sb status
  sb=$(make_sandbox)
  write_home_gitconfig "$sb" "Previous Owner" ""
  status=$(run_rebuild "$sb")

  [ "$status" = 0 ] || fail "rebuild.sh failed with only one key set: $(sandbox_out "$sb")"
  assert_contains "$(sandbox_out "$sb")" "git resolves user.name to \"Previous Owner\", from $sb/home/.gitconfig." \
    "rebuild.sh did not report the one key that resolves"
  assert_contains "$(sandbox_out "$sb")" "git resolves no user.email." \
    "rebuild.sh did not report the key that resolves to nothing"
  assert_not_contains "$(sandbox_out "$sb")" "Previous Owner <" \
    "rebuild.sh assembled half an identity into an identity line"
  # shellcheck disable=SC2088
  assert_contains "$(sandbox_out "$sb")" "git config --file ~/.gitconfig.local user.email \"you@example.com\"" \
    "rebuild.sh did not say how to set the key that resolves to nothing"
  assert_not_contains "$(sandbox_out "$sb")" "git config --file ~/.gitconfig.local user.name" \
    "rebuild.sh prescribed a write for the key that already resolves"

  pass "report: one resolving key is reported as that key, never as an identity"
}

# A report is not worth an exit status. A rebuild that failed must still fail,
# with the switch's own status, and one that worked must still succeed - which
# is why `exec sudo` had to go.
test_rebuild_preserves_the_switch_exit_status() {
  local sb status
  sb=$(make_sandbox)
  printf '3\n' >"$sb/sudo-exit"
  status=$(run_rebuild "$sb")

  [ "$status" = 3 ] || fail "rebuild.sh returned $status instead of the switch's own status 3"
  assert_contains "$(sandbox_out "$sb")" "git resolves no user.name and no user.email" \
    "rebuild.sh skipped the identity report when the switch failed"

  pass "report: a failing switch keeps its exit status and is still reported on"
}

# --- step 5: the hardware seam ------------------------------------------------
#
# The repository tracks a placeholder hardware-configuration.nix so the flake
# evaluates before any machine exists. Step 5 is where that stops being true for
# the machine actually being set up: it runs nixos-generate-config and puts the
# real description in the placeholder's place.

test_bootstrap_replaces_the_placeholder_hardware_file() {
  local sb status
  sb=$(make_sandbox)
  status=$(run_bootstrap "$sb")

  [ "$status" = 0 ] || fail "bootstrap failed at the hardware step: $(sandbox_out "$sb")"
  assert_contains "$(sandbox_calls "$sb")" "nixos-generate-config --show-hardware-config" \
    "bootstrap never asked the machine to describe its own hardware"
  assert_contains "$(cat "$sb/repo/hardware-configuration.nix")" 'by-uuid/deadbeef' \
    "the generated hardware description did not replace the placeholder"
  assert_not_contains "$(cat "$sb/repo/hardware-configuration.nix")" \
    "dotfiles-nixos-placeholder-hardware-configuration" \
    "the placeholder marker survived into this machine's hardware description"
  # Order matters as much as the fact: a switch that ran before this step would
  # build the placeholder's invented disk layout into the boot entry.
  printf '%s\n' "$(sandbox_calls "$sb")" | grep -n . >"$sb/ordered"
  [ "$(grep -c 'nixos-generate-config' "$sb/ordered")" -ge 1 ] \
    || fail "the hardware step left no trace in the call log"
  [ "$(grep -m1 -n 'nixos-generate-config' "$sb/ordered" | cut -d: -f1)" \
    -lt "$(grep -m1 -n 'switch --flake' "$sb/ordered" | cut -d: -f1)" ] \
    || fail "bootstrap switched before it described the machine's hardware"

  pass "hardware: bootstrap replaces the placeholder before it reaches the switch"
}

# A generator this repo cannot fix must stop the run where the damage is
# nothing, not one step later where it is a machine configured against invented
# disk labels.
test_bootstrap_stops_before_the_switch_when_hardware_generation_fails() {
  local sb status before
  sb=$(make_sandbox)
  printf '9\n' >"$sb/hardware-exit"
  before=$(cat "$sb/repo/hardware-configuration.nix")
  status=$(run_bootstrap "$sb")

  [ "$status" != 0 ] || fail "bootstrap continued after hardware generation failed"
  assert_contains "$(sandbox_out "$sb")" "The generator failed (exit 9)" \
    "bootstrap did not report why the hardware step stopped it"
  [ "$(cat "$sb/repo/hardware-configuration.nix")" = "$before" ] \
    || fail "a failed generator still changed hardware-configuration.nix"
  case "$(sandbox_calls "$sb")" in
    *"switch --flake"*) fail "bootstrap switched with no hardware description" ;;
  esac

  pass "hardware: a failing generator stops bootstrap before the switch, changing nothing"
}

# --- preflight: this machine is not NixOS -------------------------------------
#
# bootstrap.sh drives nixos-rebuild and nixos-generate-config. On a machine
# without them every step after the symlink fails one at a time with a different
# error, so the run is refused up front - before a prompt, before a write, and
# before sudo.

test_preflight_refuses_a_machine_without_nixos_tooling() {
  local sb status
  sb=$(make_sandbox)
  rm -f "$sb/bin/nixos-rebuild" "$sb/bin/nixos-generate-config"
  # A machine that runs this suite may have the real tools on PATH, and the
  # sandbox shims are only the first entry. Pin the PATH down to the shims and
  # the system directories so "not on PATH" actually means that.
  status=$(run_bootstrap "$sb" repo $'\n' "$sb/bin:/usr/bin:/bin:/usr/sbin:/sbin")

  [ "$status" != 0 ] || fail "bootstrap ran on a machine with no NixOS tooling: $(sandbox_out "$sb")"
  assert_contains "$(sandbox_out "$sb")" "is not on this machine's PATH" \
    "bootstrap did not say which tool it could not find"
  assert_contains "$(sandbox_out "$sb")" "it expects NixOS to be" \
    "bootstrap did not say that this repository configures an installed NixOS"
  assert_not_contains "$(sandbox_out "$sb")" "Step 1" \
    "bootstrap started changing the machine before refusing"
  [ ! -e "$sb/home/.dotfiles" ] \
    || fail "bootstrap linked ~/.dotfiles on a machine it then refused"
  [ -z "$(sandbox_calls "$sb")" ] \
    || fail "bootstrap ran something before refusing: $(sandbox_calls "$sb")"

  pass "preflight: a machine without nixos-rebuild is refused before anything is written"
}

# --- preflight: this machine has no git ---------------------------------------
#
# git is the third tool bootstrap.sh cannot do without, and the only one a user
# following HOW-TO.md can plausibly arrive without: a fresh NixOS has none until
# this configuration's first switch installs one, so the guide opens
# `nix-shell -p git` for the clone. Step 4 writes the identity with
# `git config --file` and keeps git's exit status rather than aborting, and the
# report after the switch reads it back the same way - so without this guard the
# run would survive a missing git, write nothing, and then describe a machine
# whose config is fine as unreadable.

test_preflight_refuses_a_machine_without_git() {
  local sb status nogit
  sb=$(make_sandbox)
  # The NixOS shims plus `dirname`, the one external utility bootstrap.sh runs
  # before its preflight, and nothing else - so the only thing missing from this
  # PATH is git.
  nogit="$sb/nogit"
  mkdir -p "$nogit"
  ln -s "$(command -v dirname)" "$nogit/dirname"
  status=$(run_bootstrap "$sb" repo $'\n' "$sb/bin:$nogit")

  [ "$status" != 0 ] || fail "bootstrap ran on a machine with no git: $(sandbox_out "$sb")"
  assert_contains "$(sandbox_out "$sb")" "\"git\" is not on this machine's PATH" \
    "bootstrap did not say that git was the tool it could not find"
  assert_contains "$(sandbox_out "$sb")" "nix-shell -p git" \
    "bootstrap did not tell the reader where to get git"
  assert_not_contains "$(sandbox_out "$sb")" "Step 1" \
    "bootstrap started changing the machine before refusing"
  [ ! -e "$sb/home/.dotfiles" ] \
    || fail "bootstrap linked ~/.dotfiles on a machine it then refused"
  [ ! -e "$sb/home/.gitconfig.local" ] \
    || fail "bootstrap wrote an identity file on a machine it then refused"
  [ -z "$(sandbox_calls "$sb")" ] \
    || fail "bootstrap ran something before refusing: $(sandbox_calls "$sb")"

  pass "preflight: a machine without git is refused before anything is written"
}

# The negative half of the two cases above, and the only claim it makes: every
# other case already drives bootstrap this way and asserts it reaches the switch.
test_preflight_stays_quiet_on_a_machine_with_the_tooling() {
  local sb
  sb=$(make_sandbox)
  run_bootstrap "$sb" >/dev/null

  case "$(sandbox_out "$sb")" in
    *"is not on this machine's PATH"*)
      fail "bootstrap reported missing NixOS tooling while it was on PATH" ;;
  esac

  pass "preflight: the NixOS-tooling guard stays quiet when the tooling is there"
}

test_link_created_when_absent
test_link_rerun_is_idempotent
test_link_replaces_stale_symlink
test_link_when_repo_already_is_dotfiles
test_link_refuses_unrelated_directory
test_link_refuses_regular_file
test_rebuild_refuses_unrelated_directory
test_rebuild_when_repo_already_is_dotfiles
test_username_match_leaves_flake_alone
test_username_mismatch_accepted_rewrites_flake
test_username_mismatch_declined_aborts
test_machine_name_valid_is_written
test_machine_name_invalid_aborts
test_machine_name_empty_keeps_default
test_identity_written_to_gitconfig_local
test_identity_empty_keeps_existing
test_identity_preserves_unrelated_gitconfig_local
test_identity_malformed_email_is_taken_as_typed
test_identity_name_without_email_is_kept
test_identity_half_set_file_is_reported_key_by_key
test_identity_competing_gitconfig_is_reported
test_identity_unparsable_gitconfig_local_still_switches
test_identity_partial_write_failure_is_reported_per_key
test_identity_offers_no_default_from_global_config
test_report_silent_when_identity_comes_from_managed_file
test_rebuild_reports_when_no_identity_resolves
test_bootstrap_reports_identity_from_another_file
test_rebuild_silent_when_a_whole_identity_resolves_elsewhere
test_report_key_set_to_an_empty_value_names_its_file
test_report_empty_value_in_the_managed_file_is_not_called_foreign
test_report_config_git_cannot_read_repeats_gits_complaint
test_rebuild_reports_one_key_at_a_time
test_rebuild_preserves_the_switch_exit_status
test_bootstrap_replaces_the_placeholder_hardware_file
test_bootstrap_stops_before_the_switch_when_hardware_generation_fails
test_preflight_refuses_a_machine_without_nixos_tooling
test_preflight_refuses_a_machine_without_git
test_preflight_stays_quiet_on_a_machine_with_the_tooling

test_summary 38
