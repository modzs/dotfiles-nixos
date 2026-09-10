# dotfiles-nixos-placeholder-hardware-configuration
#
# THIS FILE DESCRIBES NO REAL MACHINE. It is a tracked stand-in so the flake
# evaluates - in CI, and on any checkout - before the machine it is for exists.
# `nixos-generate-config` writes the real thing per machine by inspecting the
# hardware it is run on, and bootstrap.sh overwrites this file with its output.
# Until that happens, the disk layout below is a guess and booting from it would
# fail: the labels are invented, and this claims no CPU vendor, no GPU, and none
# of the storage or network drivers a given box needs in its initrd.
#
# The sentinel on the first line is what marks the file as unreal. bootstrap.sh
# reads it to decide whether replacing this file would destroy a real machine's
# generated config, and tests/hardware-config.test.sh asserts it is still
# here. Do not remove that line while the file is still a placeholder, and do
# not add it to a generated one.
#
# nixpkgs.hostPlatform is deliberately absent: configuration.nix sets it, so the
# generated file's `lib.mkDefault "x86_64-linux"` can arrive later without
# conflicting.
{ lib, modulesPath, ... }:

{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  # A generated file lists the modules the initrd needs to reach the root
  # filesystem on that specific machine. These are the common controllers on an
  # x86_64 PC, and they are here only so the placeholder is a plausible shape -
  # not because they are right for any particular box.
  boot.initrd.availableKernelModules = [
    "ahci"
    "nvme"
    "sd_mod"
    "usbhid"
    "usb_storage"
    "xhci_pci"
  ];
  boot.initrd.kernelModules = [ ];
  # Deliberately empty. A generated file names kvm-intel or kvm-amd here, and
  # only the machine knows which; guessing one would load the wrong module.
  boot.kernelModules = [ ];
  boot.extraModulePackages = [ ];

  # NixOS refuses to evaluate a system with no root filesystem, so the
  # placeholder has to declare one. These labels are invented.
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-label/boot";
    fsType = "vfat";
    options = [ "fmask=0077" "dmask=0077" ];
  };

  swapDevices = [ ];

  networking.useDHCP = lib.mkDefault true;
}
