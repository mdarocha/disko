{
  diskoLib,
  modulesPath,
  config,
  pkgs,
  lib,
  ...
}:

let
  collectLuksNames =
    value:
    if builtins.isAttrs value then
      (lib.optional ((value.type or null) == "luks") value.name)
      ++ (lib.concatMap collectLuksNames (builtins.attrValues value))
    else if builtins.isList value then
      lib.concatMap collectLuksNames value
    else
      [ ];

  forceLuksTestPassword =
    value:
    if builtins.isAttrs value then
      if (value.type or null) == "luks" then
        (lib.mapAttrs (_: forceLuksTestPassword) value)
        // {
          askPassword = true;
          keyFile = null;
          passwordFile = null;
          settings = builtins.removeAttrs (value.settings or { }) [
            "keyFile"
            "keyFileSize"
            "keyFileOffset"
          ];
        }
      else
        lib.mapAttrs (_: forceLuksTestPassword) value
    else if builtins.isList value then
      map forceLuksTestPassword value
    else
      value;

  rawVmDiskoDevices = (diskoLib.testLib.prepareDiskoConfig config diskoLib.testLib.devices).disko.devices;
  luksDeviceNames = collectLuksNames rawVmDiskoDevices;
  vm_disko_devices = forceLuksTestPassword rawVmDiskoDevices;
  cfg_ =
    (lib.evalModules {
      modules = lib.singleton {
        # _file = toString input;
        imports = lib.singleton { disko.devices = vm_disko_devices; };
        options = {
          disko.devices = lib.mkOption {
            type = diskoLib.toplevel;
          };
          disko.testMode = lib.mkOption {
            type = lib.types.bool;
            default = true;
          };
        };
      };
    }).config;
  disks = lib.attrValues cfg_.disko.devices.disk;
  rootDisk = {
    name = "root";
    file = ''"$tmp"/${lib.escapeShellArg (builtins.head disks).imageName}.qcow2'';
    driveExtraOpts.cache = "writeback";
    driveExtraOpts.werror = "report";
    deviceExtraOpts.bootindex = "1";
    deviceExtraOpts.serial = "root";
  };
  otherDisks = map (disk: {
    name = disk.name;
    file = ''"$tmp"/${lib.escapeShellArg disk.imageName}.qcow2'';
    driveExtraOpts.werror = "report";
  }) (builtins.tail disks);

  diskoBasedConfiguration = {
    # generated from disko config
    virtualisation.fileSystems = cfg_.disko.devices._config.fileSystems;
    boot = cfg_.disko.devices._config.boot or { };
    swapDevices = cfg_.disko.devices._config.swapDevices or [ ];
  };

  hostPkgs = config.virtualisation.host.pkgs;
in
{
  imports = [
    (modulesPath + "/virtualisation/qemu-vm.nix")
    diskoBasedConfiguration
  ];

  disko.testMode = true;

  boot.initrd.luks.devices = lib.genAttrs luksDeviceNames (_: {
    keyFile = lib.mkForce null;
  });

  disko.imageBuilder.copyNixStore = false;
  disko.imageBuilder.extraConfig = {
    disko.devices = cfg_.disko.devices;
  };
  disko.imageBuilder.imageFormat = "qcow2";

  virtualisation.useEFIBoot = config.disko.tests.efi;
  virtualisation.memorySize = lib.mkDefault config.disko.memSize;
  virtualisation.useDefaultFilesystems = false;
  virtualisation.diskImage = null;
  virtualisation.qemu.drives = [ rootDisk ] ++ otherDisks;
  boot.zfs.devNodes = "/dev/disk/by-uuid"; # needed because /dev/disk/by-id is empty in qemu-vms
  boot.zfs.forceImportAll = true;
  boot.zfs.forceImportRoot = lib.mkForce true;

  system.build.vmWithDisko = hostPkgs.writers.writeDashBin "disko-vm" ''
    set -efux
    export tmp=$(${hostPkgs.coreutils}/bin/mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    ${lib.concatMapStringsSep "\n" (disk: ''
      ${hostPkgs.qemu}/bin/qemu-img create -f qcow2 \
      -b ${config.system.build.diskoImages}/${lib.escapeShellArg disk.imageName}.qcow2 \
      -F qcow2 "$tmp"/${lib.escapeShellArg disk.imageName}.qcow2
    '') disks}
    set +f
    ${config.system.build.vm}/bin/run-*-vm "$@"
  '';
}
