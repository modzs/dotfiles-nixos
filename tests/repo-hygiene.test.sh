#!/usr/bin/env bash
# Behaviour tests for what this repository tracks and what it declares.
#
# Every check runs the real consumer of the artifact under test rather than
# reading it as text: git decides what .gitignore and the index mean, and real
# TOML and JSON parsers decide what herdr's and Pi's config files declare.
#
# Coverage:
# - every script the documentation tells a reader to run as ./script is
#   executable in git's index, which is what a fresh clone actually gets;
# - the herdr runtime artifacts (~/.config/herdr is an out-of-store symlink
#   into this repo, so everything herdr writes lands in the working tree);
# - the one key herdr writes into its own tracked config.toml;
# - machine-local absolute paths in the linked Claude settings.json;
# - the package sources Pi installs from the linked global settings.json.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

dotfiles_test_parse_args "$@"

# --- documented scripts must be runnable from a fresh clone -------------------
#
# A file's executable bit lives in git's index, not just in a working tree, and
# a clone gets whatever the index says. `bootstrap.sh` and `rebuild.sh` were both
# committed 100644 once, so the very first command HOW-TO.md gives a new reader -
# `./bootstrap.sh` - died with "permission denied" (exit 126) on every fresh
# clone, while working perfectly for the author, whose local chmod never had to
# be recorded anywhere.
#
# The list of scripts is derived from the documents rather than hardcoded here,
# so a newly documented script is covered the day it is documented and this check
# cannot quietly fall behind the docs. `git ls-files -s` is git's own answer,
# which is the thing a clone reads.

test_documented_scripts_are_executable_in_the_index() {
  local report status=0

  if ! command -v python3 >/dev/null 2>&1; then
    skip "documented scripts executable in the index (python3 not found)"
    return 0
  fi

  # stderr is folded in: python reports the offending paths through sys.exit,
  # so without this the failure below would name no file.
  #
  # Single-quoted on purpose: the body below is a Python program, and the shell
  # must not expand anything inside it.
  # shellcheck disable=SC2016
  report=$(cd "$ROOT" && git ls-files -s | python3 -c '
import re, subprocess, sys

# Every `./path` token inside a fenced code block of a document a reader is
# pointed at. Fenced blocks only: prose mentions a script without telling anyone
# to run it, and `$(dirname "$0")` style paths inside the scripts are not docs.
DOCS = ("README.md", "HOW-TO.md", "CONTRIBUTING.md")
TOKEN = re.compile(r"(?<![\w./])\./([\w./-]+)")

modes = {}
for line in sys.stdin.read().splitlines():
    meta, _, path = line.partition("\t")
    modes[path] = meta.split()[0]

wanted = {}
for doc in DOCS:
    try:
        text = open(doc, encoding="utf-8").read()
    except FileNotFoundError:
        continue
    fenced = False
    for lineno, line in enumerate(text.splitlines(), 1):
        if line.strip().startswith("```"):
            fenced = not fenced
            continue
        if not fenced:
            continue
        for match in TOKEN.finditer(line):
            candidate = match.group(1).rstrip(".,;:)")
            if candidate in modes:
                wanted.setdefault(candidate, "%s:%d" % (doc, lineno))

if not wanted:
    sys.exit("no ./script invocations found in the documentation at all")

bad = [
    "%s is %s in the index but %s tells the reader to run it" % (path, modes[path], where)
    for path, where in sorted(wanted.items())
    if modes[path] != "100755"
]
if bad:
    sys.exit("; ".join(bad))
print("%d documented script(s) checked" % len(wanted))
' 2>&1) || status=$?

  [ "$status" -eq 0 ] \
    || fail "a script the documentation tells you to run is not executable in git's index, so it fails with permission denied on a fresh clone: $report - fix with: git update-index --chmod=+x <path>"

  pass "repo: every documented ./script is executable in the index ($report)"
}

# --- herdr runtime artifacts --------------------------------------------------
#
# home.nix links ~/.config/herdr straight at home/.config/herdr with
# mkOutOfStoreSymlink, so a running herdr writes its release notes, plugin
# lock, session state, logs and sockets directly into the git working tree.
# Any of those that the repo also tracks turns every herdr run into an
# unexplained `git status` diff the user has to clean up by hand.

test_herdr_runtime_artifacts_never_dirty_the_repo() {
  local sb tracked file dirty
  sb=$(dotfiles_test_tmproot dotfiles-herdr)

  # Reproduce this repo's committed state for the herdr directory in a scratch
  # repository: the working tree's .gitignore, plus every file the real repo
  # tracks under home/.config/herdr.
  git -C "$sb" init -q
  cp "$ROOT/.gitignore" "$sb/.gitignore"
  mkdir -p "$sb/home/.config/herdr"
  tracked=$(git -C "$ROOT" ls-files home/.config/herdr)
  for file in $tracked; do
    mkdir -p "$sb/$(dirname "$file")"
    cp "$ROOT/$file" "$sb/$file"
  done
  git -C "$sb" add -A
  git -C "$sb" -c user.name=dotfiles-test -c user.email=dotfiles-test@example.invalid \
    commit -qm "committed herdr state"

  # Now write what a herdr run actually leaves behind. The contents differ from
  # anything that could have been committed, so a tracked artifact shows up as a
  # modification rather than hiding behind identical bytes.
  printf '{"version":"0.0.0-test","body":"regenerated at runtime","show_on_startup":true}' \
    >"$sb/home/.config/herdr/release-notes.json"
  : >"$sb/home/.config/herdr/.plugins.lock"
  printf '{"session":"test"}' >"$sb/home/.config/herdr/session.json"
  printf 'runtime log line\n' >"$sb/home/.config/herdr/herdr-server.log"
  printf 'runtime log line\n' >"$sb/home/.config/herdr/herdr-client.log"
  : >"$sb/home/.config/herdr/herdr.sock"

  dirty=$(git -C "$sb" status --porcelain)
  [ -z "$dirty" ] \
    || fail "a herdr run dirties the repository: $(printf '%s' "$dirty" | tr '\n' ' ')"

  pass "herdr: a full set of runtime artifacts leaves the working tree clean"
}

# --- herdr's own writes into its tracked config -------------------------------
#
# config.toml is authored, so it cannot be untracked the way the runtime
# artifacts above were. herdr writes to it exactly once: when onboarding is
# dismissed it appends `onboarding = false`, which lands straight in the working
# tree. Declaring the key in the committed file leaves herdr nothing to append.

test_herdr_config_declares_onboarding() {
  if ! command -v python3 >/dev/null 2>&1; then
    skip "herdr onboarding declaration (python3 not found)"
    return 0
  fi
  if ! python3 -c 'import tomllib' >/dev/null 2>&1; then
    skip "herdr onboarding declaration (python3 has no tomllib)"
    return 0
  fi

  # A real TOML parser decides what the file declares, and it has to be a
  # top-level key: appended after a table header it would read as, say,
  # ui.onboarding, which herdr does not consult.
  python3 -c '
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    config = tomllib.load(fh)
if "onboarding" not in config:
    sys.exit("config.toml does not declare a top-level onboarding key")
if config["onboarding"] is not False:
    sys.exit("onboarding is %r, so herdr still has a value to write" % (config["onboarding"],))
' "$ROOT/home/.config/herdr/config.toml" \
    || fail "herdr can still append onboarding to the tracked config.toml"

  pass "herdr: the tracked config.toml already declares onboarding = false"
}

# --- machine-local paths in the linked Claude settings -------------------------
#
# home.nix links ~/.claude/settings.json at this file with mkOutOfStoreSymlink,
# so herdr writes its Claude SessionStart hook - `bash '/home/<name>/.claude/
# hooks/herdr-agent-state.sh' session` - straight into the working tree when the
# integration is installed or updated. That write is expected and stays local
# (see AGENTS.md); committing it is the real hazard. It would bake one machine's
# home directory into a public repo whose only personalization knob is the
# `user` variable in flake.nix, leak that username, and point every other
# machine at a script this repo does not ship.
#
# The check is deliberately about the shape, not this one hook's text: any
# absolute path into a user's home is machine-local, so a future integration
# version that writes a different command is caught too. Both /home/ and
# /Users/ are rejected: the tracked files here came from a macOS setup, and a
# path copied back from that sibling repo is just as wrong on this machine.

test_claude_settings_declare_no_machine_local_paths() {
  local settings=$ROOT/home/.claude/settings.json
  local status=0

  if ! command -v node >/dev/null 2>&1; then
    skip "Claude settings machine-local path check (node not found)"
    return 0
  fi

  # A real JSON parser walks every string value, so the failure can name where
  # the path sits rather than just reporting that the bytes matched. An
  # unreadable or malformed file exits 3, a found path exits 2, so the shell can
  # tell the two apart and never prescribe a destructive remedy for the wrong one.
  # The ${...} below are JavaScript template literals, not shell expansions.
  # shellcheck disable=SC2016
  node -e '
    const fs = require("fs");
    let settings;
    try {
      settings = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    } catch (error) {
      console.error(error.message);
      process.exit(3);
    }
    const found = [];
    const walk = (node, path) => {
      if (typeof node === "string") {
        for (const prefix of ["/home/", "/Users/"]) {
          if (node.includes(prefix)) found.push(`${path}: ${node}`);
        }
        return;
      }
      if (Array.isArray(node)) return node.forEach((v, i) => walk(v, `${path}[${i}]`));
      if (node && typeof node === "object") {
        for (const [key, value] of Object.entries(node)) walk(value, `${path}.${key}`);
      }
    };
    walk(settings, "");
    if (found.length) {
      console.error(found.join("\n"));
      process.exit(2);
    }
  ' "$settings" || status=$?

  if [ "$status" -eq 2 ]; then
    fail "home/.claude/settings.json carries an absolute home-directory path; that is a machine-local tool write - restore it with: git checkout -- home/.claude/settings.json"
  elif [ "$status" -ne 0 ]; then
    fail "home/.claude/settings.json could not be read or parsed as JSON; fix the file itself - do not run git checkout, that would discard whatever you are editing"
  fi

  pass "claude: the linked settings.json declares no machine-local home-directory path"
}

# --- Pi package sources -------------------------------------------------------
#
# Pi installs every source listed in the linked global settings.json at startup,
# with the user's full permissions. README.md commits to immutable pins only, so
# an unpinned range or a mutable git ref must not be able to slip in unnoticed.

test_pi_declares_only_immutable_npm_pins() {
  if ! command -v node >/dev/null 2>&1; then
    skip "Pi package source check (node not found)"
    return 0
  fi

  node -e '
    const fs = require("fs");
    const settings = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const packages = settings.packages;
    if (!Array.isArray(packages)) {
      console.error("settings.json declares no packages array");
      process.exit(1);
    }
    // npm:<name>@<exact semver>, where <name> may be scoped (@scope/name).
    const pinned = /^npm:(@[^/@]+\/)?[^@/]+@\d+\.\d+\.\d+$/;
    const bad = packages.filter((p) => typeof p !== "string" || !pinned.test(p));
    if (bad.length) {
      console.error("not an immutable npm pin: " + bad.join(", "));
      process.exit(1);
    }
  ' "$ROOT/home/.pi/agent/settings.json" || fail "Pi declares a package source that is not an immutable npm pin"

  pass "pi: every declared package source is an immutable npm pin"
}

test_documented_scripts_are_executable_in_the_index
test_herdr_runtime_artifacts_never_dirty_the_repo
test_herdr_config_declares_onboarding
test_claude_settings_declare_no_machine_local_paths
test_pi_declares_only_immutable_npm_pins

test_summary 5
