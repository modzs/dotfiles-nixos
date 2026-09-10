#!/usr/bin/env bash
# Behaviour tests for the cross-document contract between README.md and HOW-TO.md.
#
# The published documents are the artifact under test: GitHub renders them, and
# a reader clicking a cross-reference is the consumer. Both checks parse the
# Markdown into a semantic model rather than matching text - headings resolved
# through GitHub's anchor-slug rules, fenced blocks normalized into the command
# sequence they actually run - and assert what a reader experiences.
#
# Coverage:
# - every relative link in a tracked Markdown document lands on a real file and,
#   where it carries a fragment, on a real heading;
# - no command recipe is stated in two documents (the AGENTS.md ownership rule).
#
# The two go together: the rule is what replaces a repeated recipe with a
# cross-reference, so a rule kept without resolving links just trades a stale
# duplicate for a link into nowhere.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

dotfiles_test_parse_args "$@"

# --- cross-document links ------------------------------------------------------
#
# README.md points at HOW-TO.md sections by anchor for the steps it no longer
# spells out. GitHub does not report a fragment that matches no heading - the
# reader silently lands at the top of the file - so a renamed heading breaks the
# reference with nothing on screen to say so. The check resolves each fragment
# against the headings the target document actually declares.

test_relative_doc_links_resolve() {
  local report status=0

  if ! command -v python3 >/dev/null 2>&1; then
    skip "cross-document link resolution (python3 not found)"
    return 0
  fi

  report=$(python3 "$ROOT/tests/docs_model.py" links "$ROOT") || status=$?

  if [ "$status" -ne 0 ]; then
    fail "a relative documentation link does not resolve: $(printf '%s' "$report" | tr '\n' ' ')"
  fi

  pass "docs: every relative link lands on a real file and heading"
}

# --- one owning document per recipe --------------------------------------------
#
# AGENTS.md: a procedure must not be stated in two documents. The bug that rule
# exists for was a file-truncating command fixed in one copy of a recipe while
# the other copy kept shipping the broken form, so the thing to detect is the
# same command sequence living in two files. Repetition inside one document -
# HOW-TO's Summary restating its own steps - is a single owner, and passes.

test_no_recipe_is_stated_in_two_documents() {
  local report status=0

  if ! command -v python3 >/dev/null 2>&1; then
    skip "command-recipe ownership (python3 not found)"
    return 0
  fi

  report=$(python3 "$ROOT/tests/docs_model.py" recipes "$ROOT") || status=$?

  if [ "$status" -ne 0 ]; then
    fail "a command recipe is stated in two documents; give it one owner and cross-reference it: $(printf '%s' "$report" | tr '\n' ' ')"
  fi

  pass "docs: every command recipe is stated in exactly one document"
}

test_relative_doc_links_resolve
test_no_recipe_is_stated_in_two_documents

test_summary 2
