# Load Apple peripheral firmware (ESP:/vendorfw/firmware.cpio) at *boot* time
# instead of at *evaluation* time.
#
# Implements the algorithm from
#   https://asahilinux.org/docs/platform/open-os-interop/#os-handling
# (see https://github.com/nix-community/nixos-apple-silicon/issues/538).
# Works with both the scripted and the systemd stage-1, and with any bootloader.
#
# Sequence (bootloader):
#   0. Bootloaders that understand system.boot.extraInitrd (systemd-boot,
#      limine) load vendorfw/firmware.cpio from the ESP as an extra initrd,
#      which the kernel unpacks to /vendorfw in the initramfs.
# Sequence (stage 1, before udev starts):
#   1. If the manifest already exists, the bootloader loaded firmware.cpio as an
#      extra initrd -> nothing to mount.
#   2. Otherwise read /chosen/asahi,efi-system-partition from the device tree,
#      load nvme-apple + vfat, locate the ESP by PARTUUID (no udev needed:
#      devtmpfs already has the nodes), mount it read-only, extract the cpio
#      into /vendorfw, unmount.
#   3. Symlink /lib/firmware/vendor -> /vendorfw so stage-1 firmware loads work.
# Sequence (stage 1, after / is mounted):
#   4. Copy /vendorfw into the tmpfs declared at /lib/firmware/vendor on the
#      target root and remount it read-only. Asahi kernels search
#      /lib/firmware/vendor ahead of /lib/firmware.
#
# Failure is loud but never fatal: a machine whose firmware cannot be loaded
# still boots, it just has no Wi-Fi. Under the systemd stage-1 the units end up
# in the failed state (visible in `systemctl --failed` and the journal); under
# the scripted stage-1 they print a warning to the console.
{
  config,
  options,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hardware.asahi.vendorFirmware;

  stagingDir = "/vendorfw";
  manifestName = ".vendorfw.manifest";
  manifest = "${stagingDir}/${manifestName}";

  vendorDir = "/lib/firmware/vendor";

  espCpio = "vendorfw/firmware.cpio";

  espProperty = "/proc/device-tree/chosen/asahi,efi-system-partition";

  initrdUtilLinux = config.boot.initrd.systemd.package.util-linux;

  helpers = ''
    asahi_vendorfw_info() { echo "asahi-vendorfw: $*"; }
    asahi_vendorfw_warn() { echo "asahi-vendorfw: $*" >&2; }

    asahi_vendorfw_ready() { [ -e ${manifest} ]; }

    # Prints the ESP PARTUUID advertised by the device tree, or nothing at all
    # when this machine carries no vendor firmware package.
    asahi_vendorfw_esp_uuid() {
      if [ -e ${espProperty} ]; then
        tr -d '\0' < ${espProperty} | tr 'A-Z' 'a-z'
      fi
    }

    asahi_vendorfw_link() {
      mkdir -p /lib/firmware
      # -e follows symlinks, so a dangling link would otherwise survive here and
      # make the ln below fail.
      if [ -L ${vendorDir} ]; then
        rm -f ${vendorDir}
      fi
      if [ ! -e ${vendorDir} ]; then
        ln -s ${stagingDir} ${vendorDir}
      fi
    }
  '';

  loadFn = ''
    # --no-absolute-filenames only strips a leading "/", it does not stop an
    # entry from escaping upwards, and extraction runs as root at "/".
    asahi_vendorfw_cpio_is_safe() {
      cpio -t --quiet < "$1" 2>/dev/null | {
        while IFS= read -r entry; do
          case "$entry" in
            /* | ../* | */../* | */..) exit 1 ;;
          esac
        done
        exit 0
      }
    }

    asahi_vendorfw_wait_for_esp() {
      uuid="$1"
      asahi_vendorfw_esp=""

      # busybox's sleep is often built without sub-second support, in which case
      # `sleep 0.1` fails and a naive retry loop spins instead of waiting.
      if sleep 0.1 2>/dev/null; then
        nap="sleep 0.1"
      else
        nap="sleep 1"
      fi

      # Bound the wait by real elapsed time rather than by an attempt count, so
      # the timeout means what the option says it means. /proc/uptime is
      # truncated to whole seconds, hence -gt: -ge could give up a second early.
      read -r start _ < /proc/uptime
      start=''${start%.*}

      while :; do
        for p in /dev/nvme*n*p*; do
          if [ -b "$p" ] && [ "$(blkid -c /dev/null -o value -s PARTUUID "$p" 2>/dev/null)" = "$uuid" ]; then
            asahi_vendorfw_esp="$p"
            return 0
          fi
        done

        read -r now _ < /proc/uptime
        now=''${now%.*}
        if [ $(( now - start )) -gt ${toString cfg.espTimeout} ]; then
          return 1
        fi
        $nap
      done
    }

    asahi_vendorfw_load() {
      if asahi_vendorfw_ready; then
        asahi_vendorfw_info "firmware already supplied by the bootloader initrd"
        asahi_vendorfw_link
        return 0
      fi

      uuid=$(asahi_vendorfw_esp_uuid)
      if [ -z "$uuid" ]; then
        asahi_vendorfw_info "no asahi,efi-system-partition in the device tree, nothing to load"
        return 0
      fi

      # udev is not running yet, so devtmpfs is the only source of device nodes.
      for mod in nvme-apple vfat nls_cp437 nls_iso8859-1; do
        if ! modprobe -q "$mod"; then
          asahi_vendorfw_warn "could not load kernel module $mod"
        fi
      done

      if ! asahi_vendorfw_wait_for_esp "$uuid"; then
        asahi_vendorfw_warn "no partition with PARTUUID=$uuid appeared within ${toString cfg.espTimeout}s"
        return 1
      fi

      dev="$asahi_vendorfw_esp"
      mkdir -p /.asahi-esp ${stagingDir}

      if ! mount -t vfat -o ro,nosuid,nodev,noexec "$dev" /.asahi-esp; then
        asahi_vendorfw_warn "mounting the ESP ($dev) failed"
        rmdir /.asahi-esp 2>/dev/null || :
        return 1
      fi

      rc=0
      cpio_file=/.asahi-esp/${espCpio}
      if [ ! -f "$cpio_file" ]; then
        asahi_vendorfw_warn "$dev carries no vendorfw/firmware.cpio; re-run the Asahi installer to create it"
        rc=1
      elif ! asahi_vendorfw_cpio_is_safe "$cpio_file"; then
        asahi_vendorfw_warn "vendorfw/firmware.cpio contains absolute or parent-relative paths, refusing to extract it"
        rc=1
      else
        asahi_vendorfw_info "extracting vendor firmware from $dev"
        if ! (cd / && cpio -id --quiet --no-absolute-filenames < "$cpio_file"); then
          asahi_vendorfw_warn "extracting vendorfw/firmware.cpio failed"
          rc=1
        fi
      fi

      if ! umount /.asahi-esp; then
        asahi_vendorfw_warn "unmounting the ESP ($dev) failed"
      fi
      rmdir /.asahi-esp 2>/dev/null || :

      if [ "$rc" -ne 0 ]; then
        return "$rc"
      fi

      if ! asahi_vendorfw_ready; then
        asahi_vendorfw_warn "extraction produced no ${manifest}"
        return 1
      fi

      asahi_vendorfw_link
      return 0
    }
  '';

  forwardFn = ''
    asahi_vendorfw_forward() {
      target="$1"

      if asahi_vendorfw_ready; then
        mkdir -p "$target${vendorDir}"
        cp -a ${stagingDir}/. "$target${vendorDir}/"
        if ! mount -o remount,ro "$target${vendorDir}"; then
          asahi_vendorfw_warn "could not remount ${vendorDir} read-only"
        fi
        if [ -r "$target${vendorDir}/${manifestName}" ]; then
          asahi_vendorfw_info "vendor firmware forwarded to ${vendorDir} ($(wc -l < "$target${vendorDir}/${manifestName}") manifest entries)"
        else
          asahi_vendorfw_info "vendor firmware forwarded to ${vendorDir}"
        fi
        return 0
      fi

      if [ -z "$(asahi_vendorfw_esp_uuid)" ]; then
        asahi_vendorfw_info "this machine ships no vendor firmware, ${vendorDir} left empty"
        return 0
      fi

      asahi_vendorfw_warn "no vendor firmware was loaded; ${vendorDir} is empty and Wi-Fi, Bluetooth and other peripherals will not work"
      return 1
    }
  '';
in
{
  options.hardware.asahi.vendorFirmware = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Load the non-free non-redistributable peripheral firmware package
        (`vendorfw/firmware.cpio` on the EFI system partition, put there by the
        Asahi Installer) during early boot, and expose it at
        {file}`/lib/firmware/vendor`. This removes the need to reference the
        ESP (or a copy of the firmware) at evaluation time.

        Disable this to go back to embedding the firmware into the system
        closure with {option}`hardware.asahi.extractPeripheralFirmware` and
        {option}`hardware.asahi.peripheralFirmwareDirectory`.
      '';
    };

    bootloaderInitrd = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Ask the bootloader to load `${espCpio}` from the ESP as an additional
        initrd, so stage 1 does not have to mount the ESP itself. Only
        bootloaders supporting {option}`system.boot.extraInitrd` (systemd-boot,
        limine) honour this; everything else falls back to mounting the ESP in
        stage 1.

        Disable this if the ESP your bootloader reads from is not the one
        holding `${espCpio}`, as the bootloader may refuse to boot an entry
        whose initrd is missing.
      '';
    };

    espTimeout = lib.mkOption {
      type = lib.types.ints.positive;
      default = 10;
      description = "Seconds to wait for the internal NVMe / ESP to appear in stage 1.";
    };
  };

  config = lib.mkMerge [
    {
      # Persistent home for the firmware in the final root. Populated in stage 1,
      # then remounted read-only. Note that changing these options later causes
      # switch-to-configuration to remount the tmpfs, which empties it until the
      # next reboot.
      #
      # Exposed through config.lib so configurations that force their own
      # fileSystems (like the installer ISO) can keep it.
      lib.asahi.vendorFirmwareFileSystems =
        lib.optionalAttrs (cfg.enable && config.hardware.asahi.enable)
          {
            ${vendorDir} = {
              device = "vendorfw";
              fsType = "tmpfs";
              options = [
                "mode=0755"
                "nosuid"
                "nodev"
                "noexec"
              ];
              neededForBoot = true;
            };
          };
    }

    # Older nixpkgs lack system.boot.extraInitrd; stage 1 then always mounts the
    # ESP itself.
    (lib.optionalAttrs (options.system.boot ? extraInitrd) {
      system.boot.extraInitrd.paths = lib.mkIf (
        cfg.enable && cfg.bootloaderInitrd && config.hardware.asahi.enable
      ) [ espCpio ];
    })

    (lib.mkIf (cfg.enable && config.hardware.asahi.enable) {
      assertions = [
        {
          assertion = !config.hardware.asahi.extractPeripheralFirmware;
          message = ''
            hardware.asahi.vendorFirmware.enable and
            hardware.asahi.extractPeripheralFirmware are mutually exclusive: both
            install the same firmware, one at boot time and one at evaluation
            time.

            Drop `hardware.asahi.extractPeripheralFirmware = true` to keep
            boot-time loading, or set `hardware.asahi.vendorFirmware.enable = false`
            to keep the evaluation-time path.
          '';
        }
        {
          assertion = config.hardware.asahi.peripheralFirmwareDirectory == null;
          message = ''
            hardware.asahi.peripheralFirmwareDirectory is set, but the peripheral
            firmware is now loaded from the ESP at boot time
            (hardware.asahi.vendorFirmware.enable), which leaves that directory
            unused.

            Remove `hardware.asahi.peripheralFirmwareDirectory` (and any copy of
            firmware.cpio you keep around for it), or set
            `hardware.asahi.vendorFirmware.enable = false` to keep embedding the
            firmware at evaluation time.
          '';
        }
      ];

      fileSystems = config.lib.asahi.vendorFirmwareFileSystems;

      boot.initrd = lib.mkMerge [
        {
          # Stage-1 needs to talk to the internal NVMe and read FAT32 without udev.
          availableKernelModules = [
            "nvme-apple"
            "vfat"
            "nls_cp437"
            "nls_iso8859-1"
          ];
        }

        # ---- scripted stage-1 -------------------------------------------------
        (lib.mkIf (!config.boot.initrd.systemd.enable) {
          # busybox's cpio lacks the flags used above, so GNU cpio is required.
          # stage-1 already copies util-linux blkid (busybox's does not report
          # PARTUUID); copying it again is cheap insurance against that changing.
          extraUtilsCommands = ''
            copy_bin_and_libs ${pkgs.cpio}/bin/cpio
            copy_bin_and_libs ${pkgs.util-linux}/bin/blkid
          '';
          # Runs after boot.initrd.kernelModules are loaded and before udevd starts.
          # These are inlined into stage-1-init.sh, so they must never call `exit`.
          preDeviceCommands = ''
            ${helpers}
            ${loadFn}
            asahi_vendorfw_load || asahi_vendorfw_warn "continuing without vendor firmware"
          '';
          # Runs after every neededForBoot filesystem is mounted under $targetRoot.
          postMountCommands = ''
            ${helpers}
            ${forwardFn}
            asahi_vendorfw_forward "$targetRoot" || :
          '';
        })
        # ---- systemd stage-1 --------------------------------------------------
        (lib.mkIf config.boot.initrd.systemd.enable {
          systemd = {
            # coreutils, kmod and mount/umount are already part of the default
            # initrd; only these two are missing.
            initrdBin = [ pkgs.cpio ];
            extraBin.blkid = "${initrdUtilLinux}/bin/blkid";

            services.asahi-vendorfw-load = {
              description = "Load Apple vendor firmware from the ESP";
              unitConfig.DefaultDependencies = false;
              wantedBy = [ "sysinit.target" ];
              before = [
                "sysinit.target"
                "systemd-modules-load.service"
                "systemd-udevd.service"
                "systemd-udev-trigger.service"
              ];
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
              };
              # Only Wants=, so a failure here is recorded and logged without
              # holding up the boot.
              script = ''
                ${helpers}
                ${loadFn}
                asahi_vendorfw_load
              '';
            };

            services.asahi-vendorfw-forward = {
              description = "Forward Apple vendor firmware into the target root";
              unitConfig = {
                DefaultDependencies = false;
                RequiresMountsFor = "/sysroot${vendorDir}";
              };
              wantedBy = [ "initrd.target" ];
              after = [
                "asahi-vendorfw-load.service"
                "initrd-fs.target"
              ];
              before = [ "initrd.target" ];
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
              };
              script = ''
                ${helpers}
                ${forwardFn}
                asahi_vendorfw_forward /sysroot
              '';
            };
          };
        })
      ];
    })
  ];
}
