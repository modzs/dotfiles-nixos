# How to Use These Dotfiles

This guide takes you from "I have a PC and no operating system on it" to "my machine looks
like this configuration". It assumes you can use a terminal and git, and assumes nothing at
all about Nix or NixOS: not what a flake is, not what a generation is, not why there is no
`apt install`. [README.md](README.md) explains the ideas; this file gives you the commands.

**Read this first.** This configuration has been *evaluated* - Nix has type-checked every
option and resolved every package in it - but it has never been built, switched to, or booted
on real hardware. Nobody has run the commands in Part 2 on a real machine yet. Treat it as a
carefully checked plan, not a well-trodden path, and read
[Part 4: Undoing a Change](#part-4-undoing-a-change) before you need it.

## Table of Contents

1. [Before You Start](#before-you-start)
2. [Part 1: Install NixOS](#part-1-install-nixos)
3. [Part 2: Hand the Machine to This Repo](#part-2-hand-the-machine-to-this-repo)
4. [Part 3: The Everyday Loop](#part-3-the-everyday-loop)
5. [Part 4: Undoing a Change](#part-4-undoing-a-change)
6. [Part 5: Updating](#part-5-updating)
7. [Part 6: Customizing Your Setup](#part-6-customizing-your-setup)
8. [Troubleshooting](#troubleshooting)
9. [Summary](#summary)
10. [Quick Reference: What's Where](#quick-reference-whats-where)

---

## Before You Start

You need:

- An x86_64 PC you are willing to erase. This configuration boots with UEFI and systemd-boot,
  which every PC made in the last decade supports.
- A USB stick of 4 GB or more. Writing the installer erases it.
- A second working computer to download the installer with, and a wired or wireless network
  connection on the PC.

Two words you will meet immediately, so that the rest of this guide reads normally:

- A **generation** is one complete, finished version of your whole system - kernel, packages,
  configuration files, all of it. Every time you apply a change, NixOS builds a new generation
  and leaves the previous one on disk, bootable. This is why mistakes here are cheap.
- The **store** is `/nix/store`, where every package on the machine actually lives, each in its
  own directory named after a hash of everything that went into it. Nothing is ever installed
  "over" anything else, which is why two generations can coexist.

---

## Part 1: Install NixOS

This part is not owned by this repository - it is the standard NixOS installation, documented
in the [NixOS manual's installation
chapter](https://nixos.org/manual/nixos/stable/#sec-installation). What follows is the shortest
path through it for this configuration's target: one x86_64 PC, UEFI, whole disk. Read the
manual for anything unusual - dual boot, encrypted disks, RAID, ZFS.

### Step 1: Download the installer

Go to [nixos.org/download](https://nixos.org/download/) and get an ISO image for
**64-bit Intel/AMD**. Two are offered:

- The **Graphical ISO image** boots into a desktop and runs a point-and-click installer
  (Calamares). Take this one. It partitions the disk for you, which is the step with the most
  ways to go wrong.
- The **Minimal ISO image** boots to a text console with no installer. Take this one only if you
  want to partition by hand, and follow Step 3b below.

Either ISO installs the same NixOS. Whatever desktop you pick in the graphical installer is
temporary: Part 2 replaces the whole system configuration with this repo's, which uses GNOME.

### Step 2: Write it to the USB stick and boot it

On Linux or macOS, find the stick's device name with `lsblk` (Linux) or `diskutil list`
(macOS), then write the image. **This erases the target device, so check the name twice** -
`of=` pointing at your own disk destroys it:

```bash
sudo dd bs=4M conv=fsync oflag=direct status=progress if=nixos-graphical.iso of=/dev/sdX
```

On Windows, or if you would rather not use `dd`, use [balenaEtcher](https://etcher.balena.io/),
which picks removable devices only.

Then boot the PC from the stick. The key that opens the boot menu is usually F12, F11, F8, or
Esc, and it is shown for a moment on the manufacturer's splash screen. In the firmware settings,
make sure UEFI boot is enabled and Secure Boot is disabled - NixOS does not ship signed boot
files, so Secure Boot will refuse to start it.

### Step 3a: Install with the graphical installer

Follow the installer's screens. Two answers matter for what comes next:

- **Partitioning:** choose "Erase disk". Swap "with Hibernation" is a reasonable default if you
  have the disk space and want suspend-to-disk; plain swap or no swap is fine otherwise.
- **Users:** the username you create here is the one this repo will configure. `bootstrap.sh`
  checks it against the configuration and offers to fix a mismatch, so anything is recoverable,
  but typing the name you want now saves a step.

When it finishes, reboot and remove the USB stick.

### Step 3b: Install by hand (minimal ISO only)

Skip this if you used the graphical installer. On the minimal ISO you are logged in
automatically as `nixos`, with no password, and `sudo` needs none.

Partition the disk as GPT with an EFI system partition, a root partition, and swap. The manual's
own example, for a disk at `/dev/sda`:

```bash
sudo parted /dev/sda -- mklabel gpt
sudo parted /dev/sda -- mkpart root ext4 512MB -8GB
sudo parted /dev/sda -- mkpart swap linux-swap -8GB 100%
sudo parted /dev/sda -- mkpart ESP fat32 1MB 512MB
sudo parted /dev/sda -- set 3 esp on
```

Format them. The labels matter: they are what the mount commands below refer to.

```bash
sudo mkfs.ext4 -L nixos /dev/sda1
sudo mkswap -L swap /dev/sda2
sudo mkfs.fat -F 32 -n boot /dev/sda3
```

Mount the new system under `/mnt`:

```bash
sudo mount /dev/disk/by-label/nixos /mnt
sudo mkdir -p /mnt/boot
sudo mount -o umask=077 /dev/disk/by-label/boot /mnt/boot
sudo swapon /dev/sda2
```

Generate a starting configuration for this machine, then edit it. `nixos-generate-config`
inspects the hardware and writes two files under `/mnt/etc/nixos`: `hardware-configuration.nix`,
which describes the disks and drivers it found, and `configuration.nix`, a commented starting
point.

```bash
sudo nixos-generate-config --root /mnt
sudo nano /mnt/etc/nixos/configuration.nix
```

Two edits before you install. Uncomment the boot loader line, which the template leaves off:

```nix
boot.loader.systemd-boot.enable = true;
```

And uncomment the user account block, changing `alice` to the username you want. `wheel` is what
gives you `sudo`, which Part 2 needs:

```nix
users.users.alice = {
  isNormalUser = true;
  extraGroups = [ "wheel" ];
};
```

This account is not throwaway. The `user` line in this repo's `flake.nix` names the same
username, so declaring it here means the switch in Part 2 takes the account over rather than
creating a second one.

Then install:

```bash
sudo nixos-install
```

`nixos-install` asks for a root password at the end. Then:

```bash
sudo reboot
```

### Step 4: Log in and give your user a password

The graphical installer sets a password for the account it created, so if you used it, log in
and skip to Part 2.

After a manual install, the account you declared exists but has no password. Log in as `root`
with the password `nixos-install` asked for, and set one - replacing `john` with your username:

```bash
passwd john
```

This repo declares the user account too, but deliberately declares no password for it: a
password hash committed to a public repository is a credential handed to everyone who clones it.
`users.mutableUsers` stays at its NixOS default, so the password you set here is yours and no
switch overwrites it.

---

## Part 2: Hand the Machine to This Repo

You now have a working, plain NixOS. Everything from here is this repository.

### Step 1: Get git and clone

A fresh NixOS has no git. You do not have to install one to get past this: `nix-shell` drops you
into a shell that has a package available and leaves nothing behind afterwards.

```bash
nix-shell -p git
git clone https://github.com/modzs/dotfiles-nixos.git ~/.dotfiles
cd ~/.dotfiles
```

Cloning to `~/.dotfiles` is the simplest arrangement, because that is the path everything else
resolves through. Cloning anywhere else works too - `bootstrap.sh` makes `~/.dotfiles` a symlink
to wherever you put it.

Stay in that `nix-shell` for the rest of Part 2. `bootstrap.sh` needs git too - it writes your
git identity with git itself - and it refuses up front if git is not on your `PATH`. After the
switch in Step 3, git is installed for real and always there, so that is the point to `exit`.

### Step 2: Review the configuration before you run it

This is somebody else's machine described in a file. Read these before applying it:

- `flake.nix` - the `user` and `hostName` lines. `bootstrap.sh` prompts for both, so you do not
  have to edit them by hand, but see what they say.
- `configuration.nix` - the time zone (`time.timeZone`), the keyboard layout
  (`services.xserver.xkb.layout`), and the GNOME applications this configuration removes in
  `environment.gnome.excludePackages`.
- `home.nix` - the package list, the shell aliases, and the pinned agent CLIs.
- `home/AGENTS.md` - somebody else's instructions to their AI coding agents, which this config
  installs for Claude, Codex, and opencode. Edit or delete it if you do not want them.

[Make it yours](README.md#make-it-yours) in README.md says which of these matter and why.

### Step 3: Run bootstrap

```bash
./bootstrap.sh
```

It refuses immediately, before writing anything, if `~/.dotfiles` is already something else, or
if `nixos-rebuild`, `nixos-generate-config` or `git` is not on your `PATH`. Then it works through
six steps:

1. **Symlinks this repo to `~/.dotfiles`**, unless the repo already is `~/.dotfiles`.
2. **Checks the username.** It compares the `user = "john"` line in `flake.nix` with your actual
   username and offers to rewrite it. Answering no stops the run, because every path in the
   configuration is built from that name.
3. **Asks for the machine name.** Press Enter to keep what `flake.nix` says. NixOS applies it
   during the switch in step 6.
4. **Asks for a git name and email.** These go to `~/.gitconfig.local`, a file in your home
   directory that this repo never sees. Press Enter twice to skip.
5. **Describes this machine's real hardware.** It runs `nixos-generate-config
   --show-hardware-config` and replaces the repo's tracked placeholder
   `hardware-configuration.nix` with the result. This is the one file in the repo that becomes
   yours rather than the project's - see [The hardware seam](README.md#the-hardware-seam).
   It asks for your password here, for the first time.
6. **Builds and switches.** This downloads GNOME, the packages, and everything else, then makes
   it the running system and the default boot entry. Expect 10-30 minutes on a first run,
   depending on your connection.

### Step 4: Log out, log back in, and check

Log out of the desktop session and back in, so the new GNOME session and the new login shell
take effect. Then check a few things:

```bash
echo $SHELL
echo $EDITOR
nvim --version
```

`$SHELL` should end in `zsh` and `$EDITOR` should be `nvim`. Check that Node and the agent CLIs
came from where this repo puts them:

```bash
which node
gh-axi --version
```

`which node` should print a path under `/etc/profiles/per-user/` or `~/.nix-profile`, and
`gh-axi` should report the version pinned in `home.nix`.

Finally, check the git identity. Nothing in this repo sets one:

```bash
git config --show-origin --get user.name
git config --show-origin --get user.email
```

Each should print your own value and name `~/.gitconfig.local` as the file it came from. If some
other file is named, that file is what you actually commit as; see
[Setting the Git Identity](#setting-the-git-identity).

---

## Part 3: The Everyday Loop

There are two kinds of file in this repo, and they behave completely differently.

**Files under `home/` are live.** `~/.config/nvim`, `~/.config/wezterm`, `~/.claude/settings.json`
and the rest are symlinks pointing straight into this repo. Editing `home/.config/nvim/init.lua`
changes your Neovim config the instant you save. There is nothing to apply.

**Everything else is a description that has to be built.** `home.nix`, `configuration.nix`,
`flake.nix` - package lists, GNOME settings, the pinned CLI versions - only take effect when you
run the switch below.

### Applying changes

```bash
cd ~/.dotfiles
./rebuild.sh
```

This builds a new generation from the current state of the repo and switches the running system
to it. A rebuild with nothing to do takes seconds and is completely harmless, so when you are
unsure whether something needs one, just run it.

### Checking what will change first

`build` does everything `switch` does except change the running system. It is worth running
after an edit you are unsure about, because a switch that fails halfway is more to reason about
than a build that never ran. It needs no `sudo`, because it activates nothing:

```bash
cd ~/.dotfiles
nixos-rebuild build --flake ~/.dotfiles#pc
```

That leaves a `result` symlink in the current directory pointing at the system it built. It is
gitignored, and the next garbage collection removes what it points at once you delete it.

To see only what *would* be downloaded or compiled, without building any of it:

```bash
nixos-rebuild dry-build --flake ~/.dotfiles#pc
```

And to see how the new system would differ from the running one, package by package:

```bash
nixos-rebuild build --flake ~/.dotfiles#pc --diff
```

The comparison is always against the system running right now, so run this *before* you apply a
change. Run it just after a switch and it reports no differences, because the thing it just built
is the thing already running.

### Worked example: adding one package, start to finish

Say you want `htop`. First find out what it is called in Nixpkgs - the attribute name is what
goes in the file, and it is not always the command name:

```bash
nix search nixpkgs htop
```

Open `home.nix`:

```bash
nvim ~/.dotfiles/home.nix
```

Find `home.packages` and add a line to the list. It is a list of Nix expressions separated by
whitespace - no commas:

```nix
home.packages = with pkgs; [
  ripgrep
  fd
  fzf
  jq
  lazygit
  neovim
  htop        # <- the new one
];
```

Apply it:

```bash
cd ~/.dotfiles && ./rebuild.sh
```

Then use it:

```bash
htop
```

If the command is not found, open a new terminal - your current shell was started before the
package existed. Nothing was installed into a system directory; `htop` is in the store, and the
switch put a symlink to it in your profile.

To remove it, delete the line and run `./rebuild.sh` again. That is the whole loop: the file is
the truth, and the switch makes the machine match it.

### Committing your changes

The repository is the configuration, so keep it in git as you go:

```bash
cd ~/.dotfiles
git add -A
git commit -m "add htop"
```

Two files will usually show up as modified and should **not** be committed back to a fork you
share: `flake.nix`, which now carries your username and machine name, and
`hardware-configuration.nix`, which now describes your hardware. Both are yours. See
[`git status` Shows Changes You Never Made](#git-status-shows-changes-you-never-made) for the
files that a *tool* changed, which is a different situation with a different remedy.

---

## Part 4: Undoing a Change

This is the part that makes experimenting safe, so read it before you need it. Every switch
leaves the previous generation on disk and bootable. Nothing you do to this configuration can
leave you without a working system, as long as the machine still boots at all.

### If the machine still runs

Roll the running system back one generation:

```bash
sudo nixos-rebuild switch --rollback
```

To see what you would be rolling back to, list the generations first. This one only reads, so it
needs no `sudo` either:

```bash
nixos-rebuild list-generations
```

The active one is marked as current. Each line is a whole system: kernel version, NixOS version,
and when it was built.

### If the machine does not boot

Reboot and stop at the boot menu - systemd-boot writes one entry per generation, titled
`NixOS ... Generation 42 ...`, newest first. Pick the generation before the one that broke and
press Enter. It boots exactly the system you had then.

That gets you a working machine, but it does not change what the *next* boot does. Once you are
logged in, either fix the configuration and run `./rebuild.sh`, or make the older generation the
default again with the rollback command above.

If the boot menu does not appear at all, hold the space bar during boot - systemd-boot hides the
menu when there is nothing to choose.

### What rollback does not undo

Rolling back returns *the system* to a previous generation: packages, services, GNOME settings,
your shell. It does not undo edits to files under `home/`, because those are your repo's files,
symlinked into place rather than built - use git for those. It does not undo anything a program
wrote to your documents. And it does not undo `nix-collect-garbage -d`, which deletes the old
generations themselves; see [Freeing disk space](#freeing-disk-space).

---

## Part 5: Updating

There are two completely different things people mean by "update", and separating them is most
of understanding this repo.

**Changing the configuration** means editing a file here and running `./rebuild.sh`. Package
*versions* do not move: they are decided by `flake.lock`, which pins the exact commit of Nixpkgs
this configuration is built from. Two machines with the same `flake.lock` build the same
versions, today and in a year.

**Changing package versions** means moving that pin. `flake.lock` records, for each input in
`flake.nix`, the exact commit it currently resolves to. Updating it is a deliberate, separate
act:

```bash
cd ~/.dotfiles
nix flake update
./rebuild.sh
```

`nix flake update` rewrites `flake.lock` to the newest commit of each input's tracked branch and
changes nothing else - no packages move until the `./rebuild.sh` after it. Commit the new
`flake.lock` if you are happy with the result; if you are not, `git checkout -- flake.lock` and
rebuild to go back. To move one input only, name it:

```bash
nix flake update nixpkgs
```

This repo tracks the `nixos-26.05` channel, not the raw release branch, so an update lands on a
commit that has already been built and cached. [Why the channel and not the
branch](README.md#why-a-channel-and-not-a-branch) explains what that buys you.

### Bringing another machine up to date

If you keep this repo on more than one machine, pull first:

```bash
cd ~/.dotfiles
git pull
./rebuild.sh
```

Files under `home/` are live, so a pull updates those immediately with no rebuild involved.
Everything else needs the switch.

If `git pull` refuses because the working copy is dirty, look before discarding anything:

```bash
git status
git diff
```

`flake.nix` and `hardware-configuration.nix` are almost certainly *your* local setup, not
something to throw away - see
[A pull conflicts with your own machine's files](#a-pull-conflicts-with-your-own-machines-files).

---

## Part 6: Customizing Your Setup

### Setting the Git Identity

The identity lives in `~/.gitconfig.local`, never in this repo:

```bash
git config --file ~/.gitconfig.local user.name "Your Name"
git config --file ~/.gitconfig.local user.email "your@email.com"
```

It takes effect at once - `home.nix` already pulls that file in through `programs.git.includes`,
so no rebuild is needed. Setting the two keys this way leaves anything else in the file alone,
unlike writing the whole file with a heredoc.

### Adding Shell Aliases

Edit `home.nix` and find `programs.zsh.shellAliases`:

```nix
shellAliases = {
  ".." = "cd ..";
  "m" = "git switch main";
  "myalias" = "my command here";  # <- add new alias here
};
```

Then `./rebuild.sh`, and open a new terminal to pick it up.

### Adding a Desktop Application

There is no separate mechanism for GUI apps on NixOS - they are packages like any other, and
they go in the same `home.packages` list as the command-line tools. `wezterm`, `ghostty` and
`claude-code` are already there as examples. Add the attribute name, rebuild, and the app appears
in GNOME's launcher because Home Manager puts its `.desktop` file where GNOME looks.

If the launcher does not show it, log out and back in: GNOME reads that directory list at the
start of a session.

### Changing a GNOME Setting

GNOME settings live in a database called dconf, and this repo declares the handful it cares
about in `home.nix` under `dconf.settings`. To find the key for a setting you changed by hand in
the Settings app, ask dconf what it just wrote:

```bash
dconf watch /
```

Leave that running, change the setting in GNOME, and it prints the path and value. Add them to
`dconf.settings` in `home.nix` and rebuild. Note that integer keys often need `lib.gvariant.mkUint32`
around the number - `dconf watch` shows `uint32 30` for those.

Settings you do not declare here are still yours to change in the Settings app; they just are not
reproduced on a fresh machine.

### Bumping or Adding a Pinned npm Agent CLI

The agent CLIs (`gh-axi`, `chrome-devtools-axi`, `lavish-axi`, `tasks-axi`, `quota-axi`) are not
in Nixpkgs, so `home.nix` pins them by version and installs them into `~/.npm-global`.

Edit `home.nix` and find the `npmGlobals` attribute set near the top. It maps a package name to
an exact version, one line each:

```nix
npmGlobals = {
  "gh-axi" = "<version>";        # <- edit a version in place to bump a pin
  "some-other-cli" = "1.2.3";    # <- add a line to add a new CLI
};
```

The versions in the file are the live pins - read them there rather than from this guide. Check
what is available first:

```bash
npm view gh-axi versions --json | tail -20
```

Then `./rebuild.sh`. It compares each pin against what is already installed, installs only the
ones that differ, and prints a warning without aborting the switch if an install fails.

Do not use `npm install -g` by hand to change one of these. The next `./rebuild.sh` puts the
pinned version back, which is the point of pinning.

### Installing herdr

`herdr` is not in Nixpkgs, so this configuration cannot declare it. Install it from its own
project:

```bash
curl -fsSL https://herdr.dev/install.sh | sh
```

Upstream also publishes a flake, if you would rather run a pinned version without installing
anything:

```bash
nix run github:herdrdev/herdr/v0.9.0
```

### Installing no-mistakes

`no-mistakes` is the other tool this repo does not install for you: its installer always fetches
the latest release rather than a version you choose, and it restarts a daemon as its last act.
Neither belongs in an unattended switch. `~/.no-mistakes/bin` is already on your `PATH`, so
install it once per machine and every rebuild leaves it alone:

```bash
NO_MISTAKES_LINK_DIR="$HOME/.no-mistakes/bin" \
  curl -fsSL https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh | sh
```

Setting `NO_MISTAKES_LINK_DIR` to the install directory makes the installer skip its symlink
step, which is the only part that wanted `sudo`.

### Adding Work-Specific Configuration

Two untracked files in your home directory, outside this repo, are already wired into
`home.nix`. A work git identity goes in `~/.gitconfig.local` with the commands in
[Setting the Git Identity](#setting-the-git-identity). Environment variables and aliases go in
`~/.zshrc.local`:

```bash
cat > ~/.zshrc.local <<'EOF'
export WORK_PROXY="http://proxy.company.local:8080"
alias workvpn="openvpn --config ~/work.ovpn"
EOF
```

`programs.zsh.initContent` sources it if it exists, so nothing breaks on a machine without one,
and git never sees either file.

### Running the Tests

```bash
./tests/run.sh
```

`--strict` turns any check that had to be skipped into a failure, which is what CI runs:

```bash
./tests/run.sh --strict
```

---

## Troubleshooting

### `error: attribute 'foo' missing`

The package name you wrote does not exist in this version of Nixpkgs. Nix reports it during
evaluation, before anything is built, so nothing has changed. Find the real name:

```bash
nix search nixpkgs foo
```

Command names and attribute names often differ, and packages are occasionally renamed between
releases.

### `error: The option 'services.foo.bar' does not exist`

An option name is wrong, or belongs to a different release. This one is worth reading carefully:
the error names the file and line, and often suggests the option it thinks you meant. Search the
authoritative list at [search.nixos.org/options](https://search.nixos.org/options), which is
versioned - make sure you are looking at the same release this repo pins.

Like the error above, this is an evaluation failure. Nothing was built and nothing changed.

### The build fails partway through

A failed build changes nothing: the running system is still the previous generation, and the
partial results are unreferenced paths in the store that garbage collection will remove. Read
the last few lines - Nix prints the failing derivation and where its log is - then fix the file
and run it again.

If the error is a wall of Nix internals rather than a message, ask for the trace:

```bash
sudo nixos-rebuild switch --flake ~/.dotfiles#pc --show-trace
```

A build that *succeeded* and then failed while activating is the one case where the machine is
in a mixed state. Reboot and pick the previous generation from the boot menu; see
[Part 4: Undoing a Change](#part-4-undoing-a-change).

### `error: path ... does not exist` or a change that does nothing

Nix reads a flake through git, and it only sees files git knows about. A brand new file you have
not staged is invisible to the build, so the build either fails or quietly uses the old
contents. Stage it:

```bash
git add .
git status
```

Modified tracked files are picked up without staging - this bites only on new files.

### Freeing disk space

Every generation you keep pins every package it uses, so the store grows. Look first:

```bash
df -h /nix
du -sh /nix/store
```

Delete generations older than 30 days, keeping everything newer:

```bash
sudo nix-collect-garbage --delete-older-than 30d
```

`-d` instead deletes *all* old generations, leaving only the current one:

```bash
sudo nix-collect-garbage -d
```

Both make the generations they delete unbootable, so do not run `-d` to tidy up right after a
switch you have not lived with yet. Deleting generations does not free space on its own - it
removes the references, and the store paths go with them in the same run. After either command,
the boot menu is rewritten on your next switch, so run `./rebuild.sh` to prune the stale entries.

`nixos-rebuild build` leaves a `result` symlink behind, and anything it points at is protected
from garbage collection until you delete the symlink. Remove stale ones before running the
commands above.

### Command not found after a switch

Your shell captured its environment when it started. Open a new terminal, or:

```bash
exec zsh
```

For a GUI application that does not appear in the launcher, or a change to your session
environment, log out and back in instead.

### `git status` shows changes you never made

Some of the files this repo tracks are symlinked into your home directory, so the tools that use
them write to them here, in the working tree. Those writes are correct on your machine and wrong
for everyone else, so they are never committed.

The one you are most likely to hit: when herdr installs or updates its Claude integration it
adds a `SessionStart` hook to `home/.claude/settings.json` with your home directory spelled out
in full. Restore the file and carry on:

```bash
git checkout -- home/.claude/settings.json
```

Leave the integration installed - it is what tells herdr whether a Claude pane is working or
idle. `./tests/run.sh` fails with this same instruction if the file still carries an absolute
home-directory path.

herdr also appends settings to `home/.config/herdr/config.toml` when you change one from inside
herdr. The tracked file already declares `onboarding = false`, which is the write you would
otherwise see. Anything else that turns up there gets the same treatment: restore it, or declare
the key in the tracked file if it is a preference you mean to keep.

### A pull conflicts with your own machine's files

`git pull` refuses when an incoming commit touches a file you have uncommitted changes in. Two
files here are yours and must never be restored from git:

- `flake.nix`, which `bootstrap.sh` rewrote with your username and machine name. Restoring it
  would build the configuration for somebody else against a home directory that is not yours.
- `hardware-configuration.nix`, which `bootstrap.sh` replaced with this machine's real hardware.
  Restoring it brings back the placeholder, whose disk layout is invented, and the next switch
  would write a boot entry that cannot find your root filesystem.

Commit them on a local branch, or stash them, and pull. Do not `git checkout --` either one. If
you already did, `bootstrap.sh` can regenerate the hardware file - it asks before replacing a
real one - and Step 2 and Step 3 of Part 2 redo the `flake.nix` half.

### Wi-Fi, sound, graphics, printers

Hardware that this repo says nothing about is ordinary NixOS configuration, not a problem with
this setup. The [NixOS manual](https://nixos.org/manual/nixos/stable/) and
[search.nixos.org/options](https://search.nixos.org/options) are the places to look; the options
go in `configuration.nix` and take effect on the next `./rebuild.sh`.

---

## Summary

**First time, on a machine with NixOS already installed:**
```bash
nix-shell -p git
git clone https://github.com/modzs/dotfiles-nixos.git ~/.dotfiles
cd ~/.dotfiles
./bootstrap.sh
```

**After making changes:**
```bash
cd ~/.dotfiles && ./rebuild.sh
```

**When something breaks:**
```bash
sudo nixos-rebuild switch --rollback
```

**Key commands:**
- `./rebuild.sh` - apply configuration changes
- `nixos-rebuild build --flake ~/.dotfiles#pc` - build without applying
- `nixos-rebuild list-generations` - see what you can roll back to
- `nix search nixpkgs <name>` - find a package's attribute name
- `nix flake update` - move the pinned package versions
- `dconf watch /` - find the key behind a GNOME setting
- `exec zsh` - reload the shell after a switch

---

## Quick Reference: What's Where

| File | Purpose |
|------|---------|
| `flake.nix` | The entry point. Declares the `pc` NixOS configuration, and holds your username and machine name |
| `configuration.nix` | System settings: boot, network, locale, GNOME, fonts, the user account |
| `hardware-configuration.nix` | Your machine's disks and drivers. A placeholder until `bootstrap.sh` replaces it |
| `home.nix` | User packages, shell, prompt, GNOME settings, symlinks, pinned npm CLIs |
| `bootstrap.sh` | One-time setup on a newly installed NixOS |
| `rebuild.sh` | Apply configuration changes |
| `lib/` | Shell helpers shared by the scripts and the `home.nix` activation |
| `home/` | The real config files, symlinked into your home directory |
| `tests/` | The behaviour tests |

---

Need the reasoning rather than the commands? [README.md](README.md) covers what this repo is and
why it is built this way.
