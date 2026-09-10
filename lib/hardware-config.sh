#!/usr/bin/env bash
# lib/hardware-config.sh - the single definition of "replace the placeholder
# hardware description with this machine's real one".
#
# Sourced by bootstrap.sh. It lives here, rather than inline in that script, for
# the same reason lib/npm-globals.sh does: it is the one step that can destroy
# something the user cannot get back by re-running anything, so
# tests/hardware-config.test.sh has to be able to execute it.
#
# The seam it manages
# -------------------
# hardware-configuration.nix is generated per machine by `nixos-generate-config`
# from the hardware it is run on: initrd modules, filesystems, swap. It cannot
# be written in advance, and it cannot be shared between machines. But a flake
# that does not have one does not evaluate, so CI, `nixos-rebuild build`, and
# every pre-flight check would be impossible until the machine existed.
#
# So the repo tracks a placeholder with a sentinel on its first line, and this
# is what turns it into the real thing. The sentinel is the whole safety
# mechanism: it is the only way to tell "nobody has run this yet" from "this
# machine's real hardware description, which took a reinstall to produce".
#
# Contract, which tests/hardware-config.test.sh pins down:
#   - a placeholder is replaced without asking anything;
#   - a file with no sentinel already describes a real machine, so it is
#     replaced only after an explicit yes, and keeping it is the default;
#   - a generator that fails, or that prints something without a root
#     filesystem, leaves the existing file byte-for-byte untouched and stops.
#     A half-written or empty hardware description is the one outcome that
#     turns a recoverable mistake into a machine that will not boot;
#   - the replacement is never the target file being written in place: it is
#     produced beside it and moved over, so an interrupted run cannot leave a
#     truncated file behind.

# The first-line marker that says "this file describes no real machine".
# hardware-configuration.nix carries it; a generated file never does.
HARDWARE_CONFIG_SENTINEL="dotfiles-nixos-placeholder-hardware-configuration"

# The command that produces a real hardware description on stdout. Overridable
# so the tests can run the contract above without a Linux machine underneath
# them - nothing else has any business changing it.
: "${HARDWARE_CONFIG_CMD:=sudo nixos-generate-config --show-hardware-config}"

# True when $1 is this repo's tracked placeholder rather than a real machine's
# generated description. Only the first line is consulted: a generated file that
# happened to contain the word further down is still a generated file, and the
# placeholder puts it on line 1 precisely so this test can stay that narrow.
hardware_config_is_placeholder() {
  local file=$1 first
  [ -r "$file" ] || return 1
  IFS= read -r first <"$file" || return 1
  case $first in
    *"$HARDWARE_CONFIG_SENTINEL"*) return 0 ;;
    *) return 1 ;;
  esac
}

# printf, not echo: these lines carry a caller-supplied indent and arbitrary
# file paths, and echo would eat a leading -n or -e.
hardware_config_say() {
  printf '%s%s\n' "$1" "$2"
}

# Replace $1 with this machine's generated hardware description. $2 is an
# optional indent, so bootstrap.sh's step margin is preserved.
#
# Returns non-zero, having changed nothing, when the generator fails or produces
# something unusable, or when the user declines to overwrite a real file.
hardware_config_apply() {
  local file=$1 indent=${2:-} scratch status=0 reply

  if hardware_config_is_placeholder "$file"; then
    hardware_config_say "$indent" "$file is still the tracked placeholder."
  elif [ -e "$file" ]; then
    # Nothing here regenerates a real hardware description silently. Producing
    # one again is usually harmless, but "usually" is not good enough for the
    # file that decides whether the machine can find its own root filesystem.
    hardware_config_say "$indent" "$file already describes a real machine:"
    hardware_config_say "$indent" "it does not carry the placeholder marker, so something has"
    hardware_config_say "$indent" "generated it before."
    read -r -p "${indent}Regenerate it from this machine's hardware? [y/N] " reply || true
    case $reply in
      y|Y) : ;;
      *)
        hardware_config_say "$indent" "Keeping the existing file."
        return 0
        ;;
    esac
  else
    hardware_config_say "$indent" "$file does not exist yet."
  fi

  # Beside the target, never over it: same directory so the final move is a
  # rename within one filesystem, which either happens completely or not at all.
  scratch="$(mktemp "$file.XXXXXX")" || {
    hardware_config_say "$indent" "Could not create a scratch file next to $file."
    return 1
  }

  hardware_config_say "$indent" "Running: $HARDWARE_CONFIG_CMD"
  # Unquoted on purpose: HARDWARE_CONFIG_CMD is a command line, not a filename.
  # shellcheck disable=SC2086
  $HARDWARE_CONFIG_CMD >"$scratch" 2>"$scratch.err" || status=$?

  if [ "$status" != 0 ]; then
    hardware_config_say "$indent" "The generator failed (exit $status). $file is unchanged."
    [ -s "$scratch.err" ] && sed "s/^/${indent}  /" "$scratch.err"
    rm -f "$scratch" "$scratch.err"
    return 1
  fi

  # A generated description that declares no root filesystem would build a
  # system that cannot boot. That is worth refusing here, where the old file is
  # still intact, rather than discovering it after the reboot.
  if ! grep -q 'fileSystems\."/"' "$scratch"; then
    hardware_config_say "$indent" "The generator produced no root filesystem, so its output is not"
    hardware_config_say "$indent" "a usable hardware description. $file is unchanged."
    rm -f "$scratch" "$scratch.err"
    return 1
  fi

  rm -f "$scratch.err"
  mv "$scratch" "$file"
  hardware_config_say "$indent" "Wrote this machine's hardware description to $file."
  hardware_config_say "$indent" "It is yours, not the repo's: never restore it from git."
  return 0
}
