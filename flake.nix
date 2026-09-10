{
  description = "dotfiles-nixos";

  inputs = {
    # nixos-26.05 is the NixOS release *channel*, not the raw release-26.05
    # branch. The channel pointer only advances to commits whose NixOS jobset
    # Hydra finished building, so the binary cache can actually serve what a
    # rebuild asks for. tests/nixpkgs-channel.test.sh guards this.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    home-manager.url = "github:nix-community/home-manager/release-26.05";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, home-manager, ... }:
    let
      user = "john";
      # Machine name. bootstrap.sh can rewrite this line for you.
      # The flake output name below ("pc") is a stable config identifier and
      # deliberately does not follow the machine name; every command in this
      # repo names it explicitly, so the two never have to agree.
      hostName = "nixos";
    in
    {
      nixosConfigurations."pc" = nixpkgs.lib.nixosSystem {
        specialArgs = { inherit user hostName; };
        modules = [
          ./configuration.nix
          # Generic placeholder until bootstrap.sh replaces it with the real
          # thing on the real machine. See "The hardware seam" in README.md.
          ./hardware-configuration.nix
          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.extraSpecialArgs = { inherit user; };
            home-manager.users.${user} = import ./home.nix;
          }
        ];
      };
    };
}
