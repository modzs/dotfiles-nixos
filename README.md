# dotfiles-nixos

My personal development environment, for NixOS on an x86_64 PC with GNOME. One repo, one
command, and a machine ends up configured the same way every time.

This is a conversion of [my macOS dotfiles](https://github.com/modzs/dotfiles), which do the
same job with nix-darwin and Homebrew. The user-level half - shell, editor, terminal, agent
configuration - is nearly identical. The system half is entirely different, and most of this
document is about that difference.

**Status: evaluated, never run.** Nix has type-checked every option and resolved every package
in this configuration against the Nixpkgs commit `flake.lock` pins, and CI does that on every
change. But it has never been built, switched to, or booted on real hardware, because the
machine it is for does not exist yet. Read it as a carefully checked plan.

This README covers the architecture and the reasoning. For step-by-step commands - installing
NixOS, setup, everyday use, rollback, troubleshooting - see [HOW-TO.md](HOW-TO.md).

## Contributing / Using This Repo

These are my personal dotfiles, shared publicly so people can read them, learn from them, and
fork them freely. Feature requests and pull requests are not accepted here, and PRs are
auto-closed. If you find a bug, please open a GitHub Issue using the bug report template.

## Why this is unlike every other Linux setup

If you have configured a Linux machine before, the habit is: run `apt install` until the machine
works, edit some files in `/etc` until it works better, and hope you remember what you did. The
machine's configuration is the accumulated history of everything you ever typed at it, and the
only copy of that history is the machine.

NixOS inverts this. There is one file that says what the machine is, and a command that makes
the machine match the file. Four consequences follow, and they are the whole reason for the
extra learning:

**Packages are declared, not installed.** `htop` is not on this machine because somebody once
ran `apt install htop`; it is here because `home.nix` lists it. Delete the line, rebuild, and it
is gone - along with anything it dragged in, because nothing else claims those. There is no
equivalent of "I think I installed that for something once".

**Nothing is installed on top of anything else.** Every package lives in its own directory under
`/nix/store`, named after a hash of its exact inputs - source, compiler, dependencies, build
flags. Two versions of the same library coexist without noticing each other. A package is never
half-upgraded, because upgrading means building a new directory and pointing at that instead.

**A change is a new system, not an edit to the old one.** Applying a change builds a complete
new *generation* and switches to it. The previous one is untouched on disk and still in the boot
menu. That is why [undoing a change](HOW-TO.md#part-4-undoing-a-change) is a single command
rather than an archaeology project, and it is the single best reason to trust a machine you are
still learning. A newcomer who knows they can undo will experiment.

**The whole system lives in git.** Not dotfiles plus a wiki page of remembered steps - the boot
loader, the desktop, the user account, the fonts. A second machine built from this commit is the
same machine.

**What it costs.** This is not free, and the price is worth knowing before you commit to it:

- Everything goes through the rebuild. You cannot `pip install` something into the system, and
  a tool that expects to write to `/usr/lib` will not work as its author intended.
- Software that is not in Nixpkgs is real work to add. This repo has two such tools, and both
  are documented below as manual steps rather than pretended away.
- The error messages are about Nix expressions, not about your machine, and they take a while to
  learn to read. [Troubleshooting](HOW-TO.md#troubleshooting) covers the ones you will hit first.
- Disk usage is higher, because keeping old generations is what makes rollback work.

## What you get

Running the switch builds:

- Nix user packages (ripgrep, fd, fzf, jq, lazygit, Neovim, gh, Node, WezTerm, Ghostty, Claude Code)
- Agent CLIs from npm (`gh-axi`, `chrome-devtools-axi`, `lavish-axi`, `tasks-axi`, `quota-axi`),
  pinned and installed into `~/.npm-global`
- Shell (zsh, aliases, starship prompt), set as the login shell at system level
- Editor (Neovim config with the rose-pine moon theme)
- Terminal (WezTerm config with the rose-pine moon theme and dimmed unfocused windows)
- Agent configs (Claude, Codex, opencode all share one AGENTS.md)
- Optional Pi theme and local extensions, generic UI settings and model overrides
- A GNOME desktop with its default application suite trimmed, and a handful of settings -
  dark mode, key repeat, tap-to-click, Nautilus list view - declared rather than clicked
- The system itself: systemd-boot, NetworkManager, locale, fonts, and the user account

## Prerequisites

- An x86_64 PC with UEFI firmware, which this configuration will take over completely.
- NixOS already installed on it. This repo configures a NixOS machine; it does not install one.
  [Part 1: Install NixOS](HOW-TO.md#part-1-install-nixos) walks through the standard installer.
- Network access on the first switch, and on any switch that changes a pinned npm CLI version.
- `herdr` and `no-mistakes`, which this repo does not install for you. Both are documented in
  [Part 6](HOW-TO.md#part-6-customizing-your-setup).
- Of the three agents the installed configs are for - Claude, Codex, opencode - only Claude Code
  itself is installed. The Codex and opencode configs are written either way, so they are ready
  if you install those tools yourself; until then the `co` alias for `codex` has nothing to run.

## Architecture

Four Nix files, in the order Nix reads them:

- **`flake.nix`** is the entry point, and the only file with your name in it. It declares one
  output, `nixosConfigurations.pc`, pins its inputs in `flake.lock`, and defines the two
  variables everything else is threaded from: `user` and `hostName`. Both are lines
  `bootstrap.sh` can rewrite for you.
- **`configuration.nix`** is the system: boot loader, networking, time zone and locale, the user
  account and its groups, GNOME, fonts, and `system.stateVersion`. This is the file with no
  macOS counterpart at all.
- **`hardware-configuration.nix`** describes the machine's disks and drivers. It is generated,
  not written - see [The hardware seam](#the-hardware-seam) below.
- **`home.nix`** is everything inside your home directory, through Home Manager: packages, the
  shell, the prompt, GNOME's per-user settings, and the symlinks into `home/`.

The flake output is named `pc`, and the machine's name is a separate value. They deliberately do
not follow each other: `pc` is a stable identifier that `bootstrap.sh`, `rebuild.sh` and CI all
name explicitly, so renaming the machine cannot break the commands.

Supporting the four:

- `bootstrap.sh` - one-time setup on a newly installed NixOS: the `~/.dotfiles` link, the
  username, the machine name, the git identity, the real hardware description, and the first switch.
- `rebuild.sh` - the everyday switch.
- `lib/` - the logic both scripts share, kept in files rather than inlined so the tests can
  execute it: the `~/.dotfiles` link, the git identity report, the pinned npm installs, and the
  hardware-configuration replacement.
- `home/` - the real config files that get symlinked into place.
- `tests/` - the behaviour tests. `./tests/run.sh`, or `--strict` to fail on any check that had
  to be skipped. CI runs the strict form on every pull request, along with an evaluation of the
  flake and a shellcheck lint.

## The hardware seam

`hardware-configuration.nix` is the one file here that cannot be written in advance. NixOS
generates it per machine, by inspecting the hardware it is run on: which modules the initrd
needs to reach the root filesystem, which filesystems exist and by what UUID, whether the CPU is
Intel or AMD. It is not shareable and it is not guessable.

But a flake with no `hardware-configuration.nix` does not evaluate, and a repo whose flake does
not evaluate cannot have CI, cannot be checked before a switch, and cannot be reviewed at all -
which is a problem, since the machine this is for does not exist yet.

So the repo tracks a **placeholder**: a real Nix file with a plausible shape and a sentinel on
its first line marking it as describing no machine. The flake evaluates against it.
`bootstrap.sh` replaces it, in step 5, with what `nixos-generate-config --show-hardware-config`
prints on the real machine.

Two things follow, and both matter:

- **The placeholder's disk layout is invented.** Its labels do not exist and its module list is a
  guess. A system built from it would not boot. It is there to be type-checked, not to be run.
- **After bootstrap, that file is yours, not this repository's.** It describes your disks. Never
  restore it from git; see
  [A pull conflicts with your own machine's files](HOW-TO.md#a-pull-conflicts-with-your-own-machines-files).

`tests/hardware-config.test.sh` guards both ends: that the tracked file is still the marked
placeholder, and that the replacement refuses to damage a real one - a generator that fails, or
that prints something with no root filesystem, leaves the existing file untouched.

## What happened to the macOS configuration

### Homebrew became nixpkgs

The macOS config installs five things through Homebrew, with `onActivation.cleanup = "zap"` to
force everything to be declared. On NixOS there is nothing to reconcile: declaring packages in
Nix *is* the package manager, so `brews` and `casks` become entries in the same list as
everything else, and the cleanup setting has no counterpart because there is no second tree for
anything to hide in.

Each attribute below was checked against the Nixpkgs commit this repo pins, not assumed:

| Homebrew | Nixpkgs | Where |
|---|---|---|
| `brew "gh"` | `gh` | `home.packages` |
| `cask "wezterm"` | `wezterm` | `home.packages` |
| `cask "ghostty"` | `ghostty` | `home.packages` |
| `cask "claude-code"` | `claude-code` | `home.packages` (unfree) |
| `brew "herdr"` | **not in nixpkgs** | manual install |

**`herdr` is a real gap.** It is not in Nixpkgs under any name, so this configuration cannot
declare it and does not pretend to. Its own project publishes a Linux install script and a
flake; [Installing herdr](HOW-TO.md#installing-herdr) has both. `no-mistakes` is the second such
tool, absent from Nixpkgs and deliberately left as a manual step for a different reason - see
[Agent toolchain](#agent-toolchain).

`claude-code` is unfree, which is why `configuration.nix` sets
`nixpkgs.config.allowUnfree = true`. Unfree packages are also the one thing Hydra does not
build, so it is fetched and built locally on the first switch rather than pulled from the cache.
`tests/nixpkgs-channel.test.sh` reports it by name rather than quietly skipping it.

### macOS `system.defaults` became GNOME dconf

GNOME's settings live in dconf, and Home Manager can declare them - the same database the
Settings app writes to, so a declared key is genuinely the machine's setting rather than a file
GNOME might ignore. Five of the nine macOS settings map cleanly:

| macOS | GNOME |
|---|---|
| `AppleInterfaceStyle = "Dark"` | `org/gnome/desktop/interface` `color-scheme = "prefer-dark"`, `gtk-theme = "Adwaita-dark"` |
| `KeyRepeat = 2` | `org/gnome/desktop/peripherals/keyboard` `repeat-interval = 30` |
| `InitialKeyRepeat = 15` | `org/gnome/desktop/peripherals/keyboard` `delay = 225` |
| `trackpad.Clicking = true` | `org/gnome/desktop/peripherals/touchpad` `tap-to-click = true` |
| `finder.FXPreferredViewStyle = "Nlsv"` | `org/gnome/nautilus/preferences` `default-folder-viewer = "list-view"` |

macOS counts key repeat in 15 ms ticks and GNOME counts in milliseconds, so those two numbers are
the same speeds in GNOME's unit, not different settings.

**Four are deliberately absent, because GNOME has no equivalent.** Approximating them with
something that behaves differently would be worse than leaving them out:

- **`dock.autohide`** - GNOME has no permanent dock. The dash exists only inside the Activities
  overview, so there is nothing to auto-hide. Ubuntu's always-visible dock is an extension, not
  stock GNOME, and this configuration does not install it.
- **`_HIHideMenuBar`** - GNOME's top bar cannot be auto-hidden without a shell extension. That
  would mean depending on a third-party extension surviving every GNOME release, which is a
  bigger commitment than the setting is worth.
- **`finder.CreateDesktop = false`** - GNOME draws no desktop icons at all by default. The macOS
  setting turns something off that is already off here.
- **`AppleShowAllExtensions`** - Nautilus always shows complete file names, including extensions.
  There is no setting because there is no hiding.

GNOME's application suite is trimmed instead, in `environment.gnome.excludePackages`: the mail
client, browser, maps, music, video, contacts, calendar, help browser and the rest come out,
because each is either replaced by something in `home.packages` or unused. An app that is not
installed cannot go stale in the launcher.

### nix-darwin became NixOS

- `nix.enable = false` is gone. It existed because Determinate manages the Nix daemon on that
  Mac. NixOS manages its own daemon, and instead needs the opposite: `nix.settings.experimental-features`
  must list `nix-command` and `flakes`, or plain `nix flake update` refuses to run. (`nixos-rebuild`
  passes those features itself, which is why the *first* switch works before this option is active.)
- `system.primaryUser` and a bare `users.users.<user>.home` become a full NixOS user account:
  `isNormalUser`, the `wheel` and `networkmanager` groups, and zsh as the login shell. NixOS only
  accepts a login shell that a system module has placed in `/etc/shells`, so `programs.zsh.enable`
  is required at system level even though `home.nix` is what configures the shell.
- `home.homeDirectory` is `/home/<user>`, not `/Users/<user>`. `tests/nixos-eval.test.sh` asserts
  that, because it is the sort of thing that silently survives being copied from the sibling repo.
- No password is declared for the user, for the same reason no git identity is: this is a public
  repo, and a hash in it is a credential shipped to everyone who clones it. `users.mutableUsers`
  stays at its default, so `passwd` on the machine sets it.

### Why a channel and not a branch

`nixpkgs` tracks `nixos-26.05`. That is a *channel*, not the `release-26.05` git branch. The
channel pointer only advances to commits whose jobset Hydra has finished building and pushed to
`cache.nixos.org`, so a rebuild fetches prebuilt packages instead of compiling them locally. The
release branch has no such guarantee and moves ahead of what has been built.

`tests/nixpkgs-channel.test.sh` checks this against the systems that actually decide it: it asks
`channels.nixos.org` whether the tracked ref publishes a revision at all, and asks
`cache.nixos.org` for a substitute for every store path this configuration evaluates to.

Home Manager is pinned to the matching `release-26.05`, and `system.stateVersion` is `"26.05"`.
`stateVersion` is not a version to bump for its own sake - it pins the stateful defaults NixOS
promises not to change under a running machine.

## Make it yours

This repo is mine. If you fork it, review these before you run `bootstrap.sh`:

- **Username**: `bootstrap.sh` detects yours and offers to set it, or change the `user = "john"`
  line in `flake.nix` by hand. Everything else - `configuration.nix`, `home.nix`, the home
  directory paths - is threaded from that one variable.
- **Machine name**: `bootstrap.sh` prompts for it, or change `hostName = "nixos";` in `flake.nix`.
- **Git identity**: `bootstrap.sh` prompts and writes it to `~/.gitconfig.local`, outside this
  repo. Nothing here sets an identity.
- **Time zone and keyboard layout**: `configuration.nix` says `America/New_York` and a US
  keyboard. Neither is guessed from your machine.
- **Packages and GNOME settings**: `home.nix` for user packages, shell, and dconf;
  `configuration.nix` for the system and the GNOME applications that get excluded.

**Heads-up:**

- `home/AGENTS.md` is my personal agent policy, and `home.nix` installs it for Claude, Codex,
  and opencode. If you fork this repo, you would silently inherit my agent instructions - edit
  or delete it if you do not want that.
- The `cc` and `co` shell aliases in `home.nix` are high-agency shortcuts:
  `claude --dangerously-skip-permissions` and `codex --full-auto`. They are convenient for me,
  but know what they do before you use them.
- `home/.claude/settings.json` registers `SessionStart` hooks that run `gh-axi`,
  `chrome-devtools-axi`, and `lavish-axi` on every Claude Code session. Those three tools
  generate that block themselves; it is committed here so a fresh machine gets it without
  running anything. Delete the `hooks` key if you do not want them.
- `home/.claude/settings.json` also sets `"model": "opus"`, so every Claude Code session on this
  machine starts on Opus. That is my deliberate default, not the account one - a fork inherits
  it, and Opus is the more expensive model.
- Home Manager prepends `~/.npm-global/bin` and `~/.no-mistakes/bin` to `PATH`, so anything you
  install there shadows a same-named system binary.

## How the symlinks work

The files under `home/` are the real files - editing them here is editing your live config, with
no rebuild needed to see the change. `home.nix` uses `mkOutOfStoreSymlink` to point paths like
`~/.config/nvim` straight at `home/.config/nvim` in this repo, so the two cannot drift apart.

This is deliberately *not* how Nix usually works. A normal Home Manager file is copied into the
read-only store, which means every edit needs a rebuild and the file in your home directory
cannot be edited at all. That is the right trade for a package list and the wrong one for an
editor config you tweak twenty times an evening. The cost is that these files are outside Nix's
control: they are whatever the working tree says right now, including any local edit you have
not committed.

You only run `./rebuild.sh` for the things that are not symlinked - package lists, GNOME
settings, the pinned CLI versions.

## Agent toolchain

Seven command-line agent tools live on this machine: Node plus five npm CLIs (`gh-axi`,
`chrome-devtools-axi`, `lavish-axi`, `tasks-axi`, `quota-axi`), and `no-mistakes`.

**Node comes from nixpkgs.** `home.nix` lists `nodejs_26` in `home.packages`, so the version is
pinned by `flake.lock`. A Nix-provided node's default `npm prefix -g` is its own read-only store
path, so global npm packages have nowhere to go; this config sets
`NPM_CONFIG_PREFIX=~/.npm-global` and puts that on `PATH`, so they land in your home directory
instead.

**The five npm CLIs are pinned.** They are not in nixpkgs, so a Home Manager activation step
installs each at an exact version into that prefix. The versions are the `npmGlobals` attribute
set in `home.nix`, and it is the single source of truth: the install script in
`lib/npm-globals.sh` takes them as arguments rather than knowing any version itself.
[Bumping or Adding a Pinned npm Agent CLI](HOW-TO.md#bumping-or-adding-a-pinned-npm-agent-cli)
has the steps.

Pinning is deliberate. Unpinned, a routine rebuild could silently change a tool's behaviour
underneath you; pinned, the version only moves when you change the file and commit it. The step
is version-guarded, so a rebuild with nothing to change reads five `package.json` files and makes
no network calls, and a failed install prints a warning and lets the switch continue rather than
aborting it on a machine with no network.

**`no-mistakes` is a documented manual step, not a declared one.** Its installer always fetches
the latest release rather than a version you choose, and it restarts the `no-mistakes` daemon as
its last act. Neither belongs in an unattended `nixos-rebuild switch`. What this repo does do is
put `~/.no-mistakes/bin` on `PATH`, where the installer's binary lives, so once installed it
survives every rebuild untouched. [Installing no-mistakes](HOW-TO.md#installing-no-mistakes) has
the one-time command.

## Optional Pi configuration

Pi is an opt-in CLI, not a dependency this repository vendors. Install it from its owner with the
[official Pi instructions](https://pi.dev).

Home Manager owns exactly two repository-authored Pi directories: `~/.pi/agent/themes` and
`~/.pi/agent/extensions`. It also links `models.json` and `settings.json` as individual files.
The local extension directory is for public, repository-authored extensions only - third-party
package code never belongs there. Run `/reload` after editing a local extension or other Pi
resources. The terminal-title extension shows a spinner while Pi is working, then a completion
mark with the session name or current directory. The `rose-pine-moon` theme was authored
clean-room from the public [Rosé Pine Moon palette](https://rosepinetheme.com/palette) and Pi's
[public theme schema](https://raw.githubusercontent.com/earendil-works/pi/main/packages/coding-agent/src/modes/interactive/theme/theme-schema.json),
not from a private or live theme file.

### Pi Calm

`home/.pi/agent/extensions/calm` is a standalone local Pi extension. Home Manager's existing
global extensions-directory link makes Pi auto-load it without another declaration. `/calm`
toggles a conversation-only presentation mode and is off by default. Its choice is stored locally
in `~/.pi/agent/calm` (or the directory selected by `PI_CODING_AGENT_DIR`), not in this
repository or Home Manager. Adapted from the upstream project under the bundled MIT license,
Calm imports no modules from it and has no runtime dependency on it.

When enabled, Calm hides collapsed thinking and the call/result shells for Pi's seven built-in
tools (`read`, `bash`, `edit`, `write`, `grep`, `find`, and `ls`) without leaving blank
transcript rows. During an active run it replaces Pi's working row with a two-line animated
blue-water, yellow-boat widget. `/calm` restores Pi's stock rendering and preserves the existing
Ctrl+O tool-expansion choice.

Calm never changes prompts, tool execution, model context, session data, or ordering. `/share`
and `/export` use the complete stock transcript. Generic custom tools, images, and unsupported Pi
transcript classes deliberately remain visible because Pi has no safe general-purpose transcript
filter. If a future Pi release no longer exports the exact collapsed-thinking rendering seam,
Calm logs one diagnostic and leaves only that adapter disabled; all other behavior remains
available.

Pi's package system declares two third-party sources in the linked global `settings.json`:

- `npm:pi-web-access@0.14.0` - the exact public npm release for web access.
- `npm:@ryan_nookpi/pi-extension-codex-fast-mode@0.2.6` - the exact public npm release from
  `ryan_nookpi`.

The versions are immutable pins, so Pi does not move them during package updates. Deliberate
updates require a new source and security audit, followed by an explicit pin change in
`home/.pi/agent/settings.json`. On Pi 0.82.0, global settings declarations install missing pinned
packages automatically at startup. Pi keeps the downloaded npm package trees in its own unmanaged
`~/.pi/agent/npm` runtime directory, outside Home Manager and Git tracking.

Both packages execute with your full user permissions and must be trusted like any other
executable code.

Home Manager deliberately does not manage `~/.pi/agent` itself, or Pi authentication, sessions,
trust decisions, caches, npm package trees, or any other runtime state. The model overrides
contain no credentials or endpoint settings, do not choose a default model, and only take effect
after you authenticate Pi yourself.

## Notes

The first time you launch `nvim`, it bootstraps [lazy.nvim](https://github.com/folke/lazy.nvim)
by cloning plugins from GitHub. That needs network access once; after that it is offline.
Neovim and WezTerm both use the rose-pine moon theme. Neovim keeps italics off and uses a
transparent background so it matches the terminal setup. WezTerm's window transparency works on
GNOME's Wayland session, which composites; the macOS-only background-blur option that the sibling
repo sets has no counterpart here and is not carried over.

## License

This repo is licensed under MIT No Attribution. See `LICENSE`.
