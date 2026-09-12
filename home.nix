{ config, lib, pkgs, user, ... }:

let
  dotfiles = "${config.home.homeDirectory}/.dotfiles";

  # npm's global prefix. A Nix node's own prefix is a read-only store path, so
  # `npm install -g` needs somewhere writable, and this is it.
  npmPrefix = "${config.home.homeDirectory}/.npm-global";

  # Agent CLIs published on npm but absent from nixpkgs. Pinned on purpose:
  # unpinned, a routine `./rebuild.sh` could silently change tool versions.
  # Bump a version here, then run ./rebuild.sh.
  npmGlobals = {
    "gh-axi" = "0.1.35";
    "chrome-devtools-axi" = "0.1.34";
    "lavish-axi" = "0.1.67";
    "tasks-axi" = "0.2.5";
    "quota-axi" = "0.1.40";
  };
  npmSpecs = lib.concatStringsSep " " (
    lib.mapAttrsToList (name: version: "${name}@${version}") npmGlobals
  );
in

{
  home.username = user;
  home.homeDirectory = "/home/${user}";
  # The Home Manager release this configuration was first written against, and
  # the same release configuration.nix pins. It is not the sibling repo's value:
  # that one records when *that* machine was first set up, and no machine has
  # ever run this one. Like system.stateVersion, it pins stateful defaults rather
  # than naming a version to keep current.
  home.stateVersion = "26.05";
  home.packages = with pkgs; [
    # cli i use constantly
    ripgrep   # fast search
    fd        # fast find
    fzf       # fuzzy finder
    jq        # json on the command line
    lazygit
    neovim
    gh        # github cli
    # Neovim's `clipboard = 'unnamedplus'` (home/.config/nvim/lua/vim_config.lua)
    # needs an external provider on Linux. On macOS it found pbcopy/pbpaste in
    # the base system; NixOS's GNOME ships neither, so without one the setting is
    # inert and a yank never leaves nvim. The GNOME session this configuration
    # presents is Wayland, so wl-clipboard is the provider Neovim will use.
    wl-clipboard
    # Node itself, so the version is declared and pinned by flake.lock rather
    # than by whatever a distro package manager happens to ship. It is also what
    # markdown-preview.nvim's `build` step uses to compile its preview server
    # from vendored sources, instead of downloading a prebuilt binary - see
    # home/.config/nvim/lua/plugins/markdown.lua.
    nodejs_26
    # Desktop apps. On NixOS these are ordinary packages, so they sit in the
    # same list as everything else - there is no second package manager to
    # reconcile. home-manager installs them into the per-user profile, whose
    # share/applications GNOME already reads, so they appear in the launcher.
    wezterm
    ghostty
    claude-code
    # The browsers. configuration.nix excludes GNOME Web and says a browser
    # choice belongs here; this is that choice. Until now nothing made one, so
    # the machine had no http handler at all - `xdg-open` existed (xdg-utils
    # arrives with GNOME) but had nothing to hand a URL to, which among other
    # things left markdown-preview.nvim serving a page that never opened.
    # See xdg.mimeApps below for which of the two answers a link.
    firefox
    chromium
  ];
  # Hack Nerd Font is declared system-wide in configuration.nix, so GDM and
  # every GTK app can resolve it by name too. Repeating it here would install
  # the same store path twice and say nothing extra.
  home.sessionVariables.EDITOR = "nvim";

  home.sessionVariables.NPM_CONFIG_PREFIX = npmPrefix;
  home.sessionPath = [
    "${npmPrefix}/bin"
    # `no-mistakes` ships its own binary here; see README for the one-time install.
    "${config.home.homeDirectory}/.no-mistakes/bin"
  ];

  # The npm CLIs above are not in nixpkgs, so Home Manager installs them into the
  # writable prefix instead. The logic lives in lib/npm-globals.sh - a real script,
  # so tests/npm-globals.test.sh can execute it - and the pinned versions are passed
  # in, so npmGlobals above stays the single source of truth. Version-guarded, so a
  # rebuild with nothing to change touches the network zero times, and a failed
  # install warns instead of aborting the switch.
  home.activation.agentNpmCLIs = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    # DRY_RUN reaches activation from the caller's environment, already exported,
    # so this is a no-op today. It is here so that a Home Manager which set it as
    # a plain shell variable could not silently turn a dry run into real installs
    # in the child. Exporting only when it is set keeps the script's
    # `set, even if empty` test meaning exactly what it did inline.
    if [ -n "''${DRY_RUN+x}" ]; then export DRY_RUN; fi

    ${pkgs.bash}/bin/bash ${./lib/npm-globals.sh} \
      "${pkgs.nodejs_26}/bin" "${npmPrefix}" ${npmSpecs}
  '';

  programs.zsh = {
    enable = true;
    autosuggestion.enable = true;      # ghost text from history
    syntaxHighlighting.enable = true;  # commands turn green when valid
    initContent = ''
      bindkey '^f' autosuggest-accept
      # Machine-specific overrides (work laptops); untracked, absent is fine.
      [[ -f ~/.zshrc.local ]] && source ~/.zshrc.local
    '';
    shellAliases = {
      ".." = "cd ..";
      "add" = "git add .";
      "push" = "git push";
      "pull" = "git pull";
      "m" = "git switch main";
      "cc" = "claude --dangerously-skip-permissions";
      "co" = "codex --full-auto";
    };
  };

  programs.starship = {
    enable = true;
    settings = {
      add_newline = false;
      format = "$directory$git_branch$git_status$cmd_duration$line_break$character";
      character = {
        success_symbol = "[❯](purple)";
        error_symbol = "[❯](red)";
      };
      cmd_duration.format = "[$duration]($style) ";
    };
  };

  programs.git = {
    enable = true;
    # No name or email here on purpose: an identity in this tracked file would
    # follow every clone and fork of this repo. It lives in the untracked
    # ~/.gitconfig.local instead, which bootstrap.sh prompts for and this
    # include pulls in - the same file a work machine uses for its overrides.
    includes = [ { path = "~/.gitconfig.local"; } ];
  };

  # Which browser a link opens. Both packages above declare
  # `x-scheme-handler/http` in their desktop files, and with no
  # `[Default Applications]` entry the answer comes from GIO's registered-apps
  # ordering rather than from anything declared here - so a preview, or any
  # link, would open whichever of the two that ordering happened to surface.
  # Declaring it is what makes the answer a property of this repo.
  #
  # Firefox rather than Chromium because `chrome-devtools-axi` - one of the
  # pinned npm CLIs above - drives a Chromium-family browser over the DevTools
  # protocol for agent work. Making Chromium the default handler would land
  # every ordinary link, and every markdown preview, in the browser agents are
  # automating. Chromium stays installed and one launcher click away.
  #
  # The cost: home-manager writes ~/.config/mimeapps.list as a store symlink,
  # so GNOME Settings' "Default Applications" panel cannot change this at
  # runtime. Flipping it means this one line and a ./rebuild.sh.
  xdg.mimeApps = {
    enable = true;
    defaultApplications = {
      "x-scheme-handler/http" = "firefox.desktop";
      "x-scheme-handler/https" = "firefox.desktop";
    };
  };

  # GNOME's counterparts to the handful of macOS defaults this setup came from.
  # dconf is the real database GNOME reads, so declaring keys here is the same
  # mechanism the Settings app writes through - not a file GNOME might ignore.
  # The original macOS settings with no GNOME equivalent are deliberately
  # absent rather than approximated; README.md lists them.
  dconf.settings = {
    "org/gnome/desktop/interface" = {
      # Dark mode. color-scheme is what GTK4/libadwaita apps follow;
      # gtk-theme is the GTK3 half of the same choice.
      color-scheme = "prefer-dark";
      gtk-theme = "Adwaita-dark";
    };
    "org/gnome/desktop/peripherals/keyboard" = {
      # Key repeat. macOS counts in 15ms ticks - KeyRepeat = 2 and
      # InitialKeyRepeat = 15 - and GNOME counts in milliseconds, so these are
      # the same speeds expressed in the unit GNOME uses. Both keys are uint32
      # in the schema, and a plain Nix integer would land as int32 and be
      # rejected, hence mkUint32.
      repeat = true;
      repeat-interval = lib.gvariant.mkUint32 30;
      delay = lib.gvariant.mkUint32 225;
    };
    "org/gnome/desktop/peripherals/touchpad" = {
      tap-to-click = true;
    };
    "org/gnome/nautilus/preferences" = {
      # List view by default, the Finder "Nlsv" setting's counterpart.
      default-folder-viewer = "list-view";
    };
  };

  # Edit-in-place: the real file stays in my repo, ~/.config just points at it.
  home.file.".config/wezterm".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.config/wezterm";
  home.file.".config/nvim".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.config/nvim";
  home.file.".config/herdr".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.config/herdr";
  home.file.".claude/settings.json".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.claude/settings.json";

  # Keep Pi's credential and runtime state local by linking only authored files and directories.
  home.file.".pi/agent/themes".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.pi/agent/themes";
  home.file.".pi/agent/extensions".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.pi/agent/extensions";
  home.file.".pi/agent/models.json".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.pi/agent/models.json";
  home.file.".pi/agent/settings.json".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/.pi/agent/settings.json";

  home.file.".claude/CLAUDE.md".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/AGENTS.md";
  home.file.".codex/AGENTS.md".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/AGENTS.md";
  home.file.".config/opencode/AGENTS.md".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfiles}/home/AGENTS.md";
}
