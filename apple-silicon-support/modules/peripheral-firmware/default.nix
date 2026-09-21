{
  config,
  pkgs,
  lib,
  ...
}:
{
  imports = [
    ./load-at-boot.nix
  ];

  config = lib.mkIf config.hardware.asahi.enable {
    assertions = lib.mkIf config.hardware.asahi.extractPeripheralFirmware [
      {
        assertion = config.hardware.asahi.peripheralFirmwareDirectory != null;
        message = ''
          Asahi peripheral firmware extraction is enabled but
          hardware.asahi.peripheralFirmwareDirectory is not set.

          Point it at a directory containing firmware.cpio (copied from your
          ESP's vendorfw/), or keep hardware.asahi.vendorFirmware.enable at its
          default (true) to load the firmware from the ESP at boot time instead.
        '';
      }
    ];

    hardware.firmware =
      lib.mkIf
        (
          (config.hardware.asahi.peripheralFirmwareDirectory != null)
          && config.hardware.asahi.extractPeripheralFirmware
        )
        [
          (pkgs.stdenv.mkDerivation {
            name = "asahi-peripheral-firmware";

            nativeBuildInputs = [
              pkgs.cpio
            ];

            buildCommand = ''
              f=${config.hardware.asahi.peripheralFirmwareDirectory}/firmware.cpio
              if [ ! -f $f ]; then
                echo "firmware.cpio missing from peripheralFirmwareDirectory!"
                exit 1
              fi
              cat $f | cpio -id --quiet --no-absolute-filenames

              mkdir -p $out/lib/firmware
              mv vendorfw/* $out/lib/firmware
            '';
          })
        ];
  };

  options.hardware.asahi = {
    extractPeripheralFirmware = lib.mkOption {
      type = lib.types.bool;
      default = !config.hardware.asahi.vendorFirmware.enable;
      defaultText = lib.literalExpression "!config.hardware.asahi.vendorFirmware.enable";
      description = ''
        Extract the non-free non-redistributable peripheral firmware necessary
        for features like Wi-Fi, Webcam or ambient light sensor from
        {option}`hardware.asahi.peripheralFirmwareDirectory` at evaluation
        time, and add it to {option}`hardware.firmware`.

        By default the firmware is instead loaded from the ESP at boot time,
        see {option}`hardware.asahi.vendorFirmware.enable`.
      '';
    };

    peripheralFirmwareDirectory = lib.mkOption {
      type = lib.types.nullOr lib.types.path;

      default = null;
      example = lib.literalExpression "./vendorfw";

      description = ''
        Path to the directory containing the non-free non-redistributable
        peripheral firmware necessary for features like Wi-Fi, Webcam or
        ambient light sensor.

        It is shipped in a `vendorfw/firmware.cpio` file on the ESP and put
        there by the official Asahi Installer.

        The installer can also be invoked from MacOS a second time to re-create
        and add more firmware on an existing installation.

        Only used when {option}`hardware.asahi.extractPeripheralFirmware` is
        enabled, which requires disabling
        {option}`hardware.asahi.vendorFirmware.enable`. By default the
        firmware is loaded from the ESP at boot time instead, see
        https://asahilinux.org/docs/platform/open-os-interop/#os-handling for
        details.
      '';
    };
  };
}
