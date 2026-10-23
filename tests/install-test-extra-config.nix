{
  pkgs ? import <nixpkgs> { },
  diskoLib ? null,
  eval-config ? import <nixpkgs/nixos/lib/eval-config.nix>,
}:
let
  lib = pkgs.lib;
  host = eval-config {
    system = pkgs.stdenv.hostPlatform.system;
    modules = [
      ../module.nix
      ({ lib, ... }: {
        system.stateVersion = "25.05";
        networking.hostName = "install-test-extra-config";
        boot.loader.systemd-boot.enable = true;

        disko.devices.disk.main = {
          device = "/dev/vda";
          type = "disk";
          content = {
            type = "gpt";
            partitions = {
              ESP = {
                type = "EF00";
                size = "500M";
                content = {
                  type = "filesystem";
                  format = "vfat";
                  mountpoint = "/boot";
                };
              };
              persist = {
                size = "1G";
                content = {
                  type = "filesystem";
                  format = "ext4";
                  mountpoint = "/persist";
                };
              };
              root = {
                size = "100%";
                content = {
                  type = "filesystem";
                  format = "ext4";
                  mountpoint = "/";
                };
              };
            };
          };
        };

        disko.tests.extraConfig.disko.devices.disk.main.content.partitions.persist.size =
          lib.mkForce "100M";

        disko.tests.extraChecks = ''
          machine.succeed("test $(blockdev --getsize64 /dev/disk/by-partlabel/disk-main-persist) -eq $((100 * 1024 * 1024))")
        '';
      })
    ];
  };
in
host.config.system.build.installTest
