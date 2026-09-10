{ pkgs, user, hostName, ... }:

{
  # NixOS runs the Nix daemon itself, and flakes are still gated behind an
  # experimental-features opt-in, so the one thing this repo is built on has to
  # be declared. Without it `nixos-rebuild --flake` refuses on a stock install.
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = hostName;
  # NetworkManager owns the connections, so GNOME's own network menu configures
  # the machine rather than describing something it cannot change.
  networking.networkmanager.enable = true;

  time.timeZone = "America/New_York";
  i18n.defaultLocale = "en_US.UTF-8";

  nixpkgs.hostPlatform = "x86_64-linux";
  nixpkgs.config.allowUnfree = true;

  # zsh has to be enabled at system level as well as in home.nix: NixOS only
  # accepts a login shell that some system module has put in /etc/shells, and
  # this is what generates the /etc/zshenv that makes a login zsh find the
  # environment at all. Home Manager configures that shell; it cannot make the
  # system offer it.
  programs.zsh.enable = true;

  users.users.${user} = {
    isNormalUser = true;
    home = "/home/${user}";
    shell = pkgs.zsh;
    # wheel: sudo, which every ./rebuild.sh needs.
    # networkmanager: change wifi and VPN from the GNOME menu without a prompt.
    extraGroups = [ "wheel" "networkmanager" ];
  };
  # No password is declared here on purpose, for the same reason no git identity
  # is: this is a public repo people fork, and a hash committed to it is a
  # credential shipped to everyone. users.mutableUsers stays at its default, so
  # `passwd` on the machine is what sets it. See README.md.

  services.xserver.enable = true;
  services.displayManager.gdm.enable = true;
  services.desktopManager.gnome.enable = true;
  # X11 keymap. Wayland sessions read the same option through GNOME.
  services.xserver.xkb.layout = "us";

  # GNOME ships a full application suite. Everything below is either replaced by
  # something in home.nix (a terminal, an editor, a browser choice) or unused on
  # this machine, and an app that is not installed cannot go stale in the
  # launcher. Trimming here rather than uninstalling later is the whole point of
  # a declarative desktop.
  environment.gnome.excludePackages = with pkgs; [
    epiphany        # GNOME Web
    geary           # mail
    gnome-calendar
    gnome-characters
    gnome-clocks
    gnome-connections
    gnome-contacts
    gnome-console   # WezTerm is the terminal here
    gnome-logs
    gnome-maps
    gnome-music
    gnome-text-editor  # Neovim is the editor here
    gnome-tour
    gnome-weather
    simple-scan
    totem           # Videos
    yelp            # the help browser
  ];

  # Hack Nerd Font is what WezTerm and Neovim render in, so it belongs to the
  # system rather than to one user: GDM and any GTK app that asks for it by name
  # need it too. home.nix does not repeat it.
  fonts.packages = [ pkgs.nerd-fonts.hack ];

  # The release this configuration was written against. It is not a version to
  # bump for its own sake - it pins the stateful defaults (database layouts and
  # the like) that NixOS promises not to change under a running machine. Change
  # it only after reading the release notes for what it would migrate.
  system.stateVersion = "26.05";
}
