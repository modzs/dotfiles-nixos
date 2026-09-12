# Project notes for agents

This repository is a NixOS conversion of a nix-darwin/Homebrew macOS setup
([modzs/dotfiles](https://github.com/modzs/dotfiles)). The user-level half is close to the
original; the system half has no counterpart there. When something looks like it was copied from
that repo, check whether it still makes sense here before extending it - several of the entries
below exist because a macOS reason does not apply.

Deliberate decisions in this repo - do NOT silently revert them:

- **The configuration has been evaluated, never built or booted.** No commit, comment, doc line
  or commit message may imply otherwise. `tests/nixos-eval.test.sh` proves what is actually
  provable from any machine with Nix: `system.build.toplevel` resolves to a derivation. That is
  a plan, not a result. If you ever do build or boot it, say so precisely and update README.md's
  status paragraph rather than softening it.
- **`hardware-configuration.nix` is a tracked placeholder, and the sentinel on its first line is
  the mechanism.** A flake with no hardware file does not evaluate, so CI and every pre-switch
  check would be impossible until the machine existed. `lib/hardware-config.sh` reads that
  sentinel to tell "nobody has bootstrapped yet" from "this machine's real, irreplaceable
  hardware description", and `bootstrap.sh` step 5 does the replacement. Do not delete the
  sentinel, do not commit a real machine's generated file, and do not make the replacement
  overwrite a real file without asking. `tests/hardware-config.test.sh` guards all of it. The
  seam is documented in README.md ("The hardware seam") so a reader cannot mistake the
  placeholder's invented disk labels for hardware detection.
- **The git identity is deliberately absent from `home.nix`**: this is a public repo people fork,
  so an identity there would follow every clone. `bootstrap.sh` step 4 prompts for it and writes
  it to the untracked `~/.gitconfig.local`, which `programs.git.includes` pulls in. Do not add
  `programs.git.settings.user` back, and never commit `~/.gitconfig.local`.
- **No user password is declared either, for the same reason.** A hash in a public repo is a
  credential shipped to everyone who clones it. `users.mutableUsers` stays at its default so
  `passwd` on the machine sets it. Do not add `initialPassword` or `hashedPassword` "to make
  first boot easier".
- The git identity report lives once, in `lib/git-identity.sh`, and both `bootstrap.sh` and
  `rebuild.sh` call it only AFTER the switch: the switch is what installs `programs.git.includes`,
  so an earlier answer describes a machine that no longer exists. It reports the value and origin
  `git config --show-origin` names, never a claim about how git ranks config files, and never a
  remedy for a key that some file already sets. The mode argument is the whole difference between
  the two callers: `bootstrap.sh` passes `full` and runs once, so it also names the file behind an
  identity resolving from somewhere other than `~/.gitconfig.local`; `rebuild.sh` passes
  `missing-only` and runs on every switch, so it speaks only about a key git resolves to nothing.
  Keep that split in the one function - duplicating it into the two scripts is the drift this file
  exists to prevent. `rebuild.sh` therefore cannot become `exec sudo`; it keeps and re-raises the
  switch's exit status, and reports the identity only when that status is 0 - after a failed switch
  the last line has to be the failure, not friendly git advice.
- **The sibling repo's guard for a missing rebuild tool is deliberately NOT carried over here.**
  There, `rebuild.sh` resolves `darwin-rebuild`'s absolute path and hands sudo that path, because
  nix-darwin *installs* `darwin-rebuild` and a shell opened before the first switch never learned
  its PATH entry. NixOS has no such window: `nixos-rebuild` is in `environment.systemPackages` on a
  stock install, `/run/current-system/sw` is the last `environment.profiles` entry so its `bin` is
  on every login shell's PATH, and NixOS builds sudo with no `--with-secure-path` and writes no
  `Defaults secure_path`, so sudo keeps the caller's PATH rather than replacing it. A guard here
  could never fire, and `bootstrap.sh` step 6 already says so beside its own switch.
- The `~/.dotfiles` link logic lives once, in `lib/dotfiles-link.sh`, and is sourced by both
  `bootstrap.sh` and `rebuild.sh`. Do not re-inline `ln -sfn "$DIR" ~/.dotfiles` in either script:
  that form silently links *into* an existing real `~/.dotfiles` directory and exits 0.
- The npm agent-CLI install step lives in `lib/npm-globals.sh`, not inlined in `home.nix`, so
  `tests/npm-globals.test.sh` can execute it. `home.nix` passes the pins in as arguments;
  `npmGlobals` there stays the single source of truth. Do not re-inline it into the activation
  string, and do not hardcode versions in the script. The versions are pinned on purpose:
  unpinned, a routine `./rebuild.sh` would silently change tool behaviour.
- **`NPM_CONFIG_PREFIX=~/.npm-global` is load-bearing, but not for the macOS reason.** In the
  sibling repo it also keeps the CLIs out of Homebrew's `cleanup = "zap"` tree; there is no such
  tree here. It is here for the remaining half: a Nix-provided node's own `npm prefix -g` is a
  read-only store path, so `npm install -g` has nowhere to write without it. Do not carry the
  Homebrew half of that explanation across, and do not remove the variable.
- **`NODE_EXTRA_CA_CERTS` was dropped on purpose and must not be restored from the sibling repo.**
  There it points every Node at the CA bundle because a *Homebrew*-built node looks for roots in
  an empty `/opt/homebrew/etc/openssl@3`. There is no Homebrew node here, and NixOS already puts
  the system bundle where OpenSSL looks, so the variable would state a fact rather than fix a
  problem.
- **`herdr` and `no-mistakes` are not in nixpkgs and are deliberately manual.** herdr has no
  nixpkgs attribute at all - verify before claiming otherwise, and do not invent one; README.md
  and HOW-TO.md name its own install script and upstream flake. `no-mistakes` is absent for a
  different reason: its installer always fetches the latest release and restarts a daemon, which
  does not belong in an unattended switch. `home.sessionPath` carries `~/.no-mistakes/bin` so an
  installed copy survives every rebuild.
- **The macOS `system.defaults` with no GNOME equivalent are omitted, not approximated**:
  dock auto-hide (GNOME has no permanent dock), auto-hidden menu bar (needs a third-party shell
  extension), clean desktop (GNOME draws no desktop icons anyway), and show-all-extensions
  (Nautilus always shows full names). README.md lists them with the reasoning. Do not "restore"
  one with an extension or a setting that behaves differently.
- **`nix.settings.experimental-features` must stay.** NixOS gates `nix-command` and `flakes`
  behind it, and without them a plain `nix flake update` refuses to run. The *first* switch works
  regardless, because `nixos-rebuild` passes `--extra-experimental-features` itself - do not
  conclude from that that the option is redundant.
- **`programs.zsh.enable` in `configuration.nix` is not a duplicate of `home.nix`'s zsh.** NixOS
  only accepts a login shell that a system module has put in `/etc/shells`, and this is what
  generates the `/etc/zshenv` a login zsh needs. Home Manager configures that shell; it cannot
  make the system offer it. `tests/nixos-eval.test.sh` asserts both halves together.
- The `nixpkgs` input tracks `nixos-26.05`, the NixOS release *channel*, not the `release-26.05`
  git branch. The channel pointer only advances to commits Hydra has finished building, so the
  binary cache is reliable and `./rebuild.sh` does not fall back to compiling from source. Do not
  "modernize" it to the generic branch. `tests/nixpkgs-channel.test.sh` guards this by asking
  channels.nixos.org and cache.nixos.org. That test excludes unfree packages from the cache
  check on purpose - Hydra does not build them, so `claude-code` is never cached - and names them
  in its result rather than dropping them silently.
- The flake output is `nixosConfigurations.pc`, and the machine name is a separate `hostName`
  value. They deliberately do not follow each other: `pc` is a stable identifier that
  `bootstrap.sh`, `rebuild.sh`, CI and the tests all name explicitly. Renaming it means changing
  every one of them.
- **The `home/` files are `mkOutOfStoreSymlink`s, which is deliberately not how Nix usually
  works.** They are edited in place with no rebuild, at the cost of being outside Nix's control.
  Do not "fix" them into ordinary Home Manager files; that trade is the point, and README.md
  explains it.
- The `model` in `home/.claude/settings.json` is the repo owner's deliberate default for every
  Claude Code session on the machine. Keep the short alias form (a dated model id rots); do not
  drop the key to fall back to the account default. A first session on a 1M-context account
  rewrites the alias to `"opus[1m]"` in place once - expected, one-time, and still Opus - but do
  not commit that value: the bracketed form encodes an account entitlement, not a repo choice.
- `skipDangerousModePermissionPrompt: true` in the same file is intentional: this machine runs
  agents unattended, and the startup prompt would block them. Do not remove it as a "hardening" fix.
- herdr writes a `SessionStart` hook into `home/.claude/settings.json` with an absolute home
  directory path when its Claude integration is installed or updated. Expected, machine-local,
  and never committed - the path is one machine's home and the script is not in this repo. The
  remedy is `git checkout -- home/.claude/settings.json`; `tests/repo-hygiene.test.sh` fails on
  any absolute `/home/` or `/Users/` path in that file. Both prefixes are checked because these
  files were converted from a macOS repo.
- Do NOT stop that write with `herdr integration uninstall claude`. Worker state is classified
  from herdr's native agent state, which that hook is the source of, so uninstalling trades a
  rare cosmetic diff for losing the ability to tell a working agent from a dead one. There is no
  cleaner mechanism: Claude Code has exactly one user-scope settings file, and herdr only ever
  writes there.
- `onboarding = false` in `home/.config/herdr/config.toml` is a real preference, not stray runtime
  state: herdr appends that key the first time onboarding is dismissed, and `~/.config/herdr` is an
  out-of-store symlink, so an undeclared key lands as an unexplained diff. Declaring it leaves herdr
  nothing to write. `tests/repo-hygiene.test.sh` guards it with a real TOML parser, which is why the
  CI test job pins python3.
- There is deliberately NO activation-time or rebuild-time `Lazy! sync`. The repo owner was offered
  exactly that - a headless sync during the switch, so plugins are on disk when `./rebuild.sh`
  finishes - and chose the existing behaviour instead: lazy.nvim fetches on the next `nvim` launch,
  the same as every other plugin here. Adding a sync step to `rebuild.sh`, `bootstrap.sh` or a Home
  Manager activation script reverses a decision he made, not an oversight.
- `nvim-treesitter` is deliberately ABSENT, even though `render-markdown.nvim` renders through
  tree-sitter. The `neovim` in `home.packages` bundles the `markdown` and `markdown_inline` parsers
  it needs - verified against this repo's own nixpkgs pin, not inherited from the sibling repo's -
  and because that nvim comes from the pinned nixpkgs, `flake.lock` pins those parsers with it,
  whereas parsers `nvim-treesitter` compiles at runtime would be pinned by nothing here. Adding the
  plugin would make the config LESS reproducible, not more. Anyone adding it anyway will find
  `master` broken on the Neovim 0.12 this flake pins: render-markdown throws `attempt to call method
  'range' (a nil value)` out of nvim-treesitter's injection predicate and places no marks at all, so
  it would have to be `branch = 'main'` plus the `tree-sitter` CLI.
- `markdown-preview.nvim` is declared with `ft` only and deliberately WITHOUT `cmd`, even though
  upstream's own lazy.nvim README shows both - which is why this keeps being proposed. The
  mechanism, and what a `cmd` stub actually costs here, is recorded beside the spec in
  `home/.config/nvim/lua/plugins/markdown.lua`.
- **`firefox` and `chromium` are both installed, and NO default `http`/`https` handler is
  declared - both halves are deliberate.** The repo owner asked for both browsers. Until they
  arrived the machine had none at all - `configuration.nix` excludes GNOME Web and nothing
  replaced it - so `xdg-open` existed but had nothing to hand a URL to, and
  `markdown-preview.nvim` served a page that never opened. The default is left undeclared because
  declaring it through `xdg.mimeApps` makes `~/.config/mimeapps.list` a read-only store symlink,
  which takes the choice away from GNOME Settings on the owner's own desktop; a default he can
  change there is worth more here than one this repo decides. The cost is understood and accepted:
  with no `[Default Applications]` entry, glib answers from its own registered-apps ordering, which
  nothing here controls, so which browser opens a link is GNOME's business rather than this repo's.
  Do NOT add `xdg.mimeApps`, `force = true`, `home-manager.backupFileExtension`, or a
  `g:mkdp_browser` setting to make the answer deterministic - each has been proposed and declined.
- Tests live in `tests/` and run with `./tests/run.sh` (`--strict` fails on any skipped check).
  A check that could not run must report `skip -`, never `ok -`; CI runs the strict form, so a
  new environment-dependent test needs its dependency added to `.github/workflows/ci.yml`.
  Every test file ends with `test_summary <n>`, an asserted count, and `tests/run.sh` asserts the
  number of test *files* - so a check that quietly stopped running reports a mismatch rather than
  a smaller success. Update both counts in the same commit that changes what runs.
- **The test suite must stay runnable on a machine that is not the machine it configures.** This
  repo is edited from macOS, so tests avoid GNU-only behaviour - `sed -i` above all, whose
  spelling differs between GNU and BSD sed. This is a constraint on the *suite*, not on the repo:
  the scripts run on NixOS, which has GNU coreutils, and there is no rule here against using
  them. `bootstrap.sh` still rewrites `flake.nix` through a temp file and a rename, because that
  is atomic for a file the machine's identity depends on, and because it lets the suite exercise
  the real script rather than skipping it.
- **There is no `/bin/bash` on NixOS.** The system creates only `/bin/sh` and `/usr/bin/env`, so
  every script here carries a `#!/usr/bin/env bash` shebang, and nothing may name an absolute
  interpreter path. Every place that dispatches a script - `tests/run.sh`,
  `tests/npm-globals.test.sh` and `tests/bootstrap.test.sh`'s `run_script` - hands it to
  `"$BASH"`, the path PATH resolved for the running interpreter at startup. That form neither
  names a `/bin` path nor depends on the dispatched file's executable bit, and it survives the one
  case that pins PATH down on purpose to prove a tool is missing from it. CI runs on ubuntu, where
  `/bin/bash` does exist, so no test can catch a regression here for you.
  `home.nix`'s `${pkgs.bash}/bin/bash` is a store path, not this, and is correct as it stands.
- **`tests/pi-calm.test.sh` asserts the `~/.pi/agent/extensions` Home Manager link against the
  tracked `home.nix` text, and that is a deliberate, settled exception** to this repo's general
  preference for executing behaviour over reading source. An evaluated form has to reach
  `home.file.".pi/agent/extensions".source.drvAttrs.buildCommand`: `mkOutOfStoreSymlink` is a
  `pkgs.runCommandLocal` (home-manager `modules/files.nix`), so the repo path it links to exists
  only inside that derivation's build command, and `drvAttrs` stops carrying it as soon as nixpkgs
  flips `structuredAttrsByDefault` - today `false` by default in
  `pkgs/stdenv/generic/make-derivation.nix`. Such a check would go red for a reason that has
  nothing to do with the link it claims to test, while the text assertion covers the same contract
  against a surface that does not move. This has been proposed and declined more than once; do not
  replace it with an evaluated one.
- **The assertions and waiting behaviour of `test_real_pi_tui_smoke` in `tests/pi-calm.test.sh` are
  deliberately kept identical to the copy in the sibling
  [modzs/dotfiles](https://github.com/modzs/dotfiles) repo.** That function exercises the vendored
  Calm extension both repos ship, so improving it in only one of them makes two copies of the same
  test silently disagree about what that extension guarantees - worse than either flaw below. What
  is frozen is what the function asserts and how long it waits: the same checks, the same loop
  counts, the same sleeps, the same break conditions and the same failure messages. A change to any
  of those belongs in the sibling repo first, and then in both.
  The one deliberate divergence is the retry loops' variable name: they are `for _ in $(seq 1 120)`
  here where the sibling writes `for i in ...`, and this function's `local` line does not declare
  `i`. Nothing reads that counter - the loops mean "try up to 120 times", not "count" - and the
  only thing keeping the sibling's `i` from tripping shellcheck's SC2034 is its uncalled
  `wait_for_text` helper, which this repo does not carry. Do not "restore parity" by renaming them
  back, do not import that helper to quiet the linter, and do not paper over it with a
  `# shellcheck disable=SC2034`. `.github/workflows/ci.yml`'s lint job runs shellcheck over
  `tests/*.sh` and would go red.
  The parity rule covers that one function's assertions and waiting behaviour and nothing else: the
  rest of this file is ordinary local code, and it deliberately does not match the sibling. The
  sibling's `wait_for_text` helper and the file-scope tmux socket that helper needs are both absent
  here, because nothing outside the frozen function uses them - "this file does not match the
  sibling" is therefore not a defect.
  Two flaws inside the function are known and accepted: (a) it opens its own tmux server on a
  function-local `socket="pi-calm-smoke-$$"` and kills it only on the happy path, and no EXIT trap
  covers that socket, so a mid-test failure leaves the server and its `pi` process behind - on an
  ephemeral CI runner they die with the job; (b) `tmux` re-wraps a pane on a width change rather
  than clearing it, so the post-resize `grep -Fq '\__/'` can match the boat row drawn before the
  resize, which means the check does not strictly prove Calm repainted. Both have been raised and
  declined.
- A procedure must not be stated in two documents: one owns it, and the other keeps the context
  and the warnings and cross-references the owner instead of repeating the steps - a duplicated
  recipe is how a bug once got fixed in one copy and missed in the other. HOW-TO.md owns
  step-by-step commands and troubleshooting; README.md owns architecture, rationale and
  orientation, and carries no fenced command blocks at all. Naming a command in a sentence is not
  a recipe. `tests/docs-links.test.sh` enforces both this and the cross-reference anchors.
- **HOW-TO.md is written for someone who has never used NixOS or Nix**, at the captain's explicit
  request, and it owns the whole path from a bare PC to a configured machine - including the
  upstream install, which it cross-references rather than reproduces. Do not compress it back
  into a reference for people who already know Nix, and do not paste the NixOS manual into it.
- Never commit `.no-mistakes/` validation evidence to this public repo. `.no-mistakes/` is
  gitignored; if a validation pipeline stages evidence into a branch, drop it before merging.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
