#!/bin/sh

set -e

CONFIG=configuration.nix
CONFIG_DIR=/mnt/etc/nixos
HARDWARE_CONFIG=hardware-configuration.nix
KEY_BPOOL=bpool-key-luks
KEY_RPOOL=rpool-key-zfs
PART_BPOOL=2
PART_ESP=1
PART_RPOOL=3
PART_SWAP=4
PARTSIZE_BPOOL=4G
PARTSIZE_ESP=256M
PARTSIZE_RPOOL=
PARTSIZE_SWAP=32G
NIXOS_RELEASE=21.11
TIMEZONE=
YES=

usage()
{
    echo "Usage: ${0} -d <disk> -h <host> -r <rpool> -t <tz> -u <user> [-s <swap>] [-k <keymap>] [-R <rel>] [-y]"
    echo "    -d <disk>     Path to disk device."
    echo "    -h <host>     Hostname."
    echo "    -r <rpool>    Size of rpool partition including unit (default: all available space)."
    echo "    -t <tz>       Time zone."
    echo "    -u <user>     Default user."
    echo "    -s <swap>     Size of swap partition including unit (default: 32G)."
    echo "    -k <keymap>   Key map (default: us)."
    echo "    -R <rel>      NixOS release (default: 21.11)."
    echo "    -y            Answer yes to all prompts."
    exit 1
}

fail()
{
    echo ${1}
    exit 1
}

fail_usage()
{
    echo ${1}
    usage
}

prompt()
{
    printf "${1}, proceed? (y/N) "
    [ "${YES}" = 1 ] && echo y && return
    read input
    echo "${input}" | grep -qE '^[Yy]([Ee][Ss])?$'
    if [ ${?} -ne 0 ]; then
        fail "No changes made"
    fi
}

wait_for_path()
{
    start=$(date +%s)
    end=$((${start}+60))
    while true; do
        [ $(date +%s) -lt ${end} ] || fail "Timeout waiting for ${1}"
        device=$(readlink -f "${1}") && [ -r "${device}" ] && break
        sleep 1
    done
}

partition_disk()
{
    sgdisk --zap-all ${DISK}
    sgdisk -n${PART_ESP}:0:+${PARTSIZE_ESP} -t${PART_ESP}:EF00 ${DISK}
    sgdisk -n${PART_BPOOL}:0:+${PARTSIZE_BPOOL} -t${PART_BPOOL}:BE00 ${DISK}
    if [ -n "${PARTSIZE_SWAP}" ]; then
        sgdisk -n${PART_SWAP}:0:+${PARTSIZE_SWAP} -t${PART_SWAP}:8200 ${DISK}
    fi
    if [ -z "${PARTSIZE_RPOOL}" ]; then
        sgdisk -n${PART_RPOOL}:0:0 -t${PART_RPOOL}:BF00 ${DISK}
    else
        sgdisk -n${PART_RPOOL}:0:+${PARTSIZE_RPOOL}G -t${PART_RPOOL}:BF00 ${DISK}
    fi
}

create_encryption_key()
{
     chars='a-zA-Z0-9~!@#$%^&*_-'
     head -c 250 /dev/urandom | tr -dc ${chars} | fold -w 32 | head -n 1 | tr -d '\n'
}

create_encryption_keys()
{
    (umask 077
     mkdir -p /run/cryptkeys
     umask 277
     create_encryption_key > /run/cryptkeys/${KEY_BPOOL}
     create_encryption_key > /run/cryptkeys/${KEY_RPOOL})
}

create_rpool()
{
    wait_for_path "${DISK}-part${PART_RPOOL}"
    zpool create \
        -o ashift=12 \
        -o autotrim=on \
        -O acltype=posixacl \
        -O canmount=off \
        -O compression=zstd \
        -O dnodesize=auto \
        -O normalization=formD \
        -O relatime=on \
        -O xattr=sa \
        -O mountpoint=/ \
        -R /mnt \
        rpool \
        "${DISK}-part${PART_RPOOL}"
}

create_bpool()
{
    wait_for_path "${DISK}-part${PART_BPOOL}"

    # Create LUKS container.
    cryptsetup luksFormat -q \
        --type luks1 \
        --pbkdf-force-iterations 300000 \
        --key-file /run/cryptkeys/${KEY_BPOOL} ${DISK}-part${PART_BPOOL}
    echo -n ${DEFAULT_PASSWD} | cryptsetup luksAddKey \
        --pbkdf-force-iterations 300000 \
        --key-file /run/cryptkeys/${KEY_BPOOL} ${DISK}-part${PART_BPOOL}
    cryptsetup open \
        ${DISK}-part${PART_BPOOL} $(basename ${DISK})-part${PART_BPOOL}-luks-bpool \
        --key-file /run/cryptkeys/${KEY_BPOOL}

    # Create pool.
    zpool create \
        -d -o feature@async_destroy=enabled \
        -o feature@bookmarks=enabled \
        -o feature@embedded_data=enabled \
        -o feature@empty_bpobj=enabled \
        -o feature@enabled_txg=enabled \
        -o feature@extensible_dataset=enabled \
        -o feature@filesystem_limits=enabled \
        -o feature@hole_birth=enabled \
        -o feature@large_blocks=enabled \
        -o feature@lz4_compress=enabled \
        -o feature@spacemap_histogram=enabled \
        -o ashift=12 \
        -o autotrim=on \
        -O acltype=posixacl \
        -O canmount=off \
        -O compression=lz4 \
        -O devices=off \
        -O normalization=formD \
        -O relatime=on \
        -O xattr=sa \
        -O mountpoint=/boot \
        -R /mnt \
        bpool \
        /dev/mapper/$(basename ${DISK})-part${PART_BPOOL}-luks-bpool
}

create_rpool_datasets()
{
    # Create encrypted container under root pool for everythine else.
    zfs create -o canmount=off -o mountpoint=none \
        -o encryption=aes-256-gcm \
        -o keylocation=file:///run/cryptkeys/${KEY_RPOOL} \
        -o keyformat=passphrase rpool/enc
    zfs set keylocation=file:///etc/cryptkey.d/${KEY_RPOOL} rpool/enc

    # Create containers for system (/nix) and data.
    zfs create -o canmount=off -o mountpoint=none rpool/enc/sys
    zfs create -o canmount=off -o mountpoint=none rpool/enc/data

    # Create / dataset and empty snapshot.
    # On each boot, / will be rolled back to the empty snapshot.
    zfs create -o mountpoint=/ -o canmount=noauto rpool/enc/data/root
    zfs snapshot rpool/enc/data/root@blank
    zfs mount rpool/enc/data/root

    # Create /home and /root.
    zfs create -o canmount=off -o mountpoint=none rpool/enc/data/users
    zfs create -o canmount=on -o mountpoint=/home rpool/enc/data/users/home
    zfs create -o canmount=on -o mountpoint=/root rpool/enc/data/users/root
    chmod 750 /mnt/root

    # Create /state dataset and bind mounts in it.
    zfs create -o canmount=on -o mountpoint=/state rpool/enc/data/state
    for path in etc/nixos:755 etc/cryptkey.d:700 etc/NetworkManager/system-connections:755; do
        directory=$(echo ${path} | cut -d: -f1)
        mode=$(echo ${path} | cut -d: -f2)
        mkdir -p /mnt/state/${directory} /mnt/${directory}
        chmod ${mode} /mnt/state/${directory}
        mount -o bind /mnt/state/${directory} /mnt/${directory}
    done

    # Create /nix.
    zfs create -o canmount=on -o mountpoint=/nix rpool/enc/sys/nix
}

create_bpool_datasets()
{
    # Create container and dataset for /boot.
    zfs create -o canmount=off -o mountpoint=none bpool/sys
    zfs create -o mountpoint=/boot -o canmount=noauto bpool/sys/boot

    # Mount /boot.
    zfs mount bpool/sys/boot
}

format_esp()
{
    mkfs.vfat -n EFI ${DISK}-part${PART_ESP}
    mkdir -p /mnt/boot/efi
    mount -t vfat ${DISK}-part${PART_ESP} /mnt/boot/efi
}

configure_nix()
{
    cat >${CONFIG_DIR}/${CONFIG} <<EOF
{ config, pkgs, ... }:

{
  imports = [ ./${HARDWARE_CONFIG} ];

  boot = {
    initrd = {
      luks.devices = {
        "$(basename ${DISK})-part${PART_BPOOL}-luks-bpool" = {
          device = "${DISK}-part${PART_BPOOL}";
          allowDiscards = true;
          keyFile = "/etc/cryptkey.d/${KEY_BPOOL}";
        };
      };
      postDeviceCommands = pkgs.lib.mkAfter ''
        zfs rollback -r rpool/enc/data/root@blank
      '';
      secrets = {
        "/etc/cryptkey.d/${KEY_RPOOL}" = "/etc/cryptkey.d/${KEY_RPOOL}";
        "/etc/cryptkey.d/${KEY_BPOOL}" = "/etc/cryptkey.d/${KEY_BPOOL}";
      };
    };
    kernelPackages = pkgs.linuxKernel.packages.linux_5_15;
    loader = {
      efi = {
        canTouchEfiVariables = false;
        efiSysMountPoint     = "/boot/efi";
      };
      generationsDir = {
        copyKernels = true;
      };
      grub = {
        copyKernels           = true;
        device                = "nodev";
        efiInstallAsRemovable = true;
        efiSupport            = true;
        enable                = true;
        enableCryptodisk      = true;
        extraPrepareConfig    = ''
          mkdir -p /boot/efi
          mount /boot/efi
        '';
        version               = 2;
        zfsSupport            = true;
      };
    };
    supportedFilesystems = [ "zfs" ];
    zfs = {
      devNodes = "/dev/disk/by-id";
    };
  };

  networking = {
    firewall.enable = false;
    hostId          = "$(head -c 8 /etc/machine-id)";
    hostName        = "${HOSTNAME}";
  };

  i18n.defaultLocale = "en_US.UTF-8";
  console.keyMap     = "${KEYMAP}";

  services.xserver = {
    displayManager = {
      autoLogin.enable   = true;
      autoLogin.user     = "${DEFAULT_USER}";
      gdm.enable         = true;
    };
    desktopManager.gnome.enable = true;
    enable                      = true;
    layout                      = "${KEYMAP}";
    xkbOptions                  = "ctrl:nocaps";
  };

  services.printing.enable   = true;

  sound.enable               = true;
  hardware.pulseaudio.enable = true;

  time.timeZone              = "${TIMEZONE}";

  users.users.${DEFAULT_USER} = {
    isNormalUser          = true;
    extraGroups           = [ "networkmanager" "wheel" ];
    initialHashedPassword = "$(echo ${DEFAULT_PASSWD} | mkpasswd -m SHA-512 -s)";
  };

  systemd.services.zfs-mount.enable = false;

  # For auto login, see https://github.com/NixOS/nixpkgs/issues/103746.
  systemd.services."getty@tty1".enable = false;
  systemd.services."autovt@tty1".enable = false;

  environment.gnome.excludePackages = with pkgs; [
    epiphany
    evince
    gnome-photos
    gnome-tour
    gnome.atomix
    gnome.cheese
    gnome.gnome-music
    gnome.gnome-characters
    gnome.hitori
    gnome.iagno
    gnome.tali
    gnome.totem
  ];

  environment.etc = {
    "machine-id".source      = "/state/etc/machine-id";
    "zfs/zpool.cache".source = "/state/etc/zfs/zpool.cache";
  };
  environment.systemPackages = with pkgs; [ chromium cryptsetup curl vim ];

  system.stateVersion        = "21.05";

  swapDevices = [{
    device                  = "${DISK}-part${PART_SWAP}";
    randomEncryption.enable = true;
  }];
}
EOF

    # Set up initial state.
    systemd-machine-id-setup --print > /mnt/state/etc/machine-id
    install -m 0755 ${0} /mnt/state

    # Copy encryption keys
    install -m 400 /run/cryptkeys/${KEY_RPOOL} /mnt/etc/cryptkey.d/${KEY_RPOOL}
    install -m 400 /run/cryptkeys/${KEY_BPOOL} /mnt/etc/cryptkey.d/${KEY_BPOOL}

    # Modify ZFS mounts in hardware configuration.
    sed -i '/swapDevices/d' ${CONFIG_DIR}/${HARDWARE_CONFIG}
    sed -i 's|fsType = "zfs";|fsType = "zfs"; options = [ "zfsutil" "X-mount.mkdir" ];|g' ${CONFIG_DIR}/${HARDWARE_CONFIG}
    sed -i 's|fsType = "vfat";|fsType = "vfat"; options = [ "x-systemd.idle-timeout=1min" "x-systemd.automount" "noauto" ];|g' \
        ${CONFIG_DIR}/${HARDWARE_CONFIG}

    # Disable cache
    mkdir -p /mnt/state/etc/zfs/
    rm -f /mnt/state/etc/zfs/zpool.cache
    touch /mnt/state/etc/zfs/zpool.cache
    chmod a-w /mnt/state/etc/zfs/zpool.cache
    chattr +i /mnt/state/etc/zfs/zpool.cache
}

while getopts 'd:h:r:s:t:u:R:k:y' arg; do
    case ${arg} in
        d) DISK=${OPTARG}
           ;;
        h) HOSTNAME=${OPTARG}
           ;;
        r) PARTSIZE_RPOOL=${OPTARG}
           ;;
        s) PARTSIZE_SWAP=${OPTARG}
           ;;
        t) TIMEZONE=${OPTARG}
           ;;
        u) DEFAULT_USER=${OPTARG}
           ;;
        R) NIXOS_RELEASE=${OPTARG}
           ;;
        k) KEYMAP=${OPTARG}
           ;;
        y) YES=1
           ;;
        ?) usage
           ;;
    esac
done

[ -n "${DISK}" ] || fail_usage "Option -d is required"
[ -n "${HOSTNAME}" ] || fail_usage "Option -h is required"
[ -n "${TIMEZONE}" ] || fail_usage "Option -t is required"
[ -n "${DEFAULT_USER}" ] || fail_usage "Option -u is required"
[ -n "${DEFAULT_PASSWD}" ] || fail_usage "Environment variable DEFAULT_PASSWD is required"
[ -n "${KEYMAP}" ] || KEYMAP=us

prompt "Disk ${DISK} will be erased"
blkdiscard -f ${DISK}

prompt "Disk ${DISK} will be partitioned"
partition_disk

create_encryption_keys

prompt "ZFS root pool on ${DISK} will be created"
create_rpool

prompt "ZFS root pool datasets will be created"
create_rpool_datasets

prompt "ZFS boot pool on ${DISK} will be created"
create_bpool

prompt "ZFS boot pool datasets will be created"
create_bpool_datasets

prompt "EFI system partition will be formatted"
format_esp

nixos-generate-config --root /mnt

configure_nix

zfs snapshot -r rpool/enc@initial
zfs snapshot -r bpool/sys@initial

nix-channel --add \
    https://nixos.org/channels/nixos-${NIXOS_RELEASE} \
    nixos-${NIXOS_RELEASE}

# Creating the same TMPDIR under both / and /mnt is a hack to work around
# the following error when nixos-install creates secrets in initrd:
# mktemp: failed to create directory via template ‘/mnt/tmp.vZBJVeeOWn/initrd-secrets.XXXXXXXXXX’: No such file or directory
install_tmpdir=$(mktemp -d -p /)
mkdir -p /mnt/${install_tmpdir}

TMPDIR=${install_tmpdir} nixos-install -v --show-trace \
    -I nixpkgs=channel:nixos-${NIXOS_RELEASE} \
    --no-root-passwd \
    --root /mnt

rm -rf ${install_tmpdir} /mnt/${install_tmpdir}

umount /mnt/boot/efi

zpool export bpool
zpool export rpool
