"""Semantic model of this repo's Markdown documents, for tests/docs-links.test.sh.

Two models, both derived from the rendered meaning of a document rather than
its bytes:

  headings(doc)  the anchors GitHub generates for the document's headings,
                 which is what a `#fragment` link actually resolves against.
  recipes(doc)   each fenced block reduced to the sequence of commands it runs,
                 so two blocks that differ only in comments or blank lines are
                 recognized as the same procedure.

Usage:  python3 tests/docs_model.py {links|recipes} <repo-root>
Exits non-zero, with the offending sites on stdout, when the model violates the
contract the test asserts.
"""

import os
import re
import sys
import unicodedata

# The documents a reader is pointed at. Everything tracked at the repo root;
# CLAUDE.md is an include shim with no prose of its own.
DOC_NAMES = ("README.md", "HOW-TO.md", "AGENTS.md", "CONTRIBUTING.md")

INLINE = (
    (re.compile(r"`([^`]*)`"), r"\1"),
    (re.compile(r"\*\*([^*]*)\*\*"), r"\1"),
    (re.compile(r"\*([^*]*)\*"), r"\1"),
    (re.compile(r"\[([^\]]*)\]\([^)]*\)"), r"\1"),
)

LINK = re.compile(r"\[([^\]]+)\]\(([^)\s]+)\)")
HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*$")
FENCE = re.compile(r"^\s*```")


def anchor(text):
    """The fragment GitHub generates for a heading: inline formatting dropped,
    lowercased, punctuation other than - and _ removed, spaces hyphenated."""
    for pattern, repl in INLINE:
        text = pattern.sub(repl, text)
    text = text.strip().lower()
    kept = [
        c
        for c in text
        if c.isalnum() or c in " -_" or unicodedata.category(c).startswith("M")
    ]
    return "".join(kept).replace(" ", "-")


def read_docs(root):
    docs = {}
    for name in DOC_NAMES:
        path = os.path.join(root, name)
        if os.path.exists(path):
            with open(path, encoding="utf-8") as handle:
                docs[name] = handle.read().splitlines()
    return docs


def headings(lines):
    """anchor -> heading text, with GitHub's -1/-2 suffixes for repeats."""
    anchors, seen, fenced = {}, {}, False
    for line in lines:
        if FENCE.match(line):
            fenced = not fenced
            continue
        if fenced:
            continue
        match = HEADING.match(line)
        if not match:
            continue
        base = anchor(match.group(2))
        count = seen.get(base, 0)
        seen[base] = count + 1
        anchors[base if count == 0 else "%s-%d" % (base, count)] = match.group(2)
    return anchors


def recipes(lines):
    """(first-line number, command tuple) for each fenced block that runs
    commands. Comments, blank lines, prompt markers and repeated whitespace do
    not change which procedure a block describes, so they are normalized away."""
    found, current, start = [], None, 0
    for lineno, line in enumerate(lines, 1):
        if FENCE.match(line):
            if current is None:
                current, start = [], lineno
            else:
                commands = tuple(
                    stripped
                    for stripped in (
                        re.sub(r"^\$ ", "", re.sub(r"\s+", " ", raw.strip()))
                        for raw in current
                    )
                    if stripped and not stripped.startswith("#")
                )
                if commands:
                    found.append((start, commands))
                current = None
            continue
        if current is not None:
            current.append(line)
    return found


def check_links(root, docs):
    anchors = {name: headings(lines) for name, lines in docs.items()}
    broken = []
    resolved = 0
    for name, lines in docs.items():
        for lineno, line in enumerate(lines, 1):
            for label, target in LINK.findall(line):
                if target.startswith(("http://", "https://", "mailto:")):
                    continue
                path, _, fragment = target.partition("#")
                where = "%s:%d [%s](%s)" % (name, lineno, label, target)
                doc = name if path == "" else os.path.normpath(path)
                if not os.path.exists(os.path.join(root, doc)):
                    broken.append("%s -> no such file %s" % (where, doc))
                    continue
                if not fragment:
                    resolved += 1
                    continue
                if doc not in anchors:
                    broken.append("%s -> %s is not a checked document" % (where, doc))
                    continue
                if fragment not in anchors[doc]:
                    broken.append(
                        "%s -> %s has no heading with anchor #%s" % (where, doc, fragment)
                    )
                    continue
                resolved += 1
                print("%s -> %s: %s" % (where, doc, anchors[doc][fragment]))
    print("%d relative link(s) resolved, %d broken" % (resolved, len(broken)))
    for entry in broken:
        print("BROKEN " + entry)
    return 1 if broken else 0


def check_recipes(_root, docs):
    owners = {}
    for name, lines in docs.items():
        for lineno, commands in recipes(lines):
            owners.setdefault(commands, []).append((name, lineno))
    violations = [
        (commands, sites)
        for commands, sites in owners.items()
        if len({name for name, _ in sites}) > 1
    ]
    print(
        "%d distinct command recipe(s), %d stated in more than one document"
        % (len(owners), len(violations))
    )
    for commands, sites in violations:
        print(
            "DUPLICATED `%s` in %s"
            % (
                " ; ".join(commands),
                ", ".join("%s:%d" % site for site in sites),
            )
        )
    return 1 if violations else 0


def main(argv):
    if len(argv) != 3 or argv[1] not in ("links", "recipes"):
        print(__doc__)
        return 2
    root = argv[2]
    docs = read_docs(root)
    if not docs:
        print("no documents found under %s" % root)
        return 2
    return check_links(root, docs) if argv[1] == "links" else check_recipes(root, docs)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
