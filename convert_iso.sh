#!/bin/bash

## Requirements, dmg2img, aria2, kpartx, hfsprogs, hfsutils, p7zip-full

set -e -uf -o pipefail
shopt -s extglob

SCRIPT=$(basename $0)
CURDIR="$(cd -P "$( dirname "${BASH_SOURCE[0]}" )" && pwd)"
ASSETS="${CURDIR}/assets"
BUILDROOT="${CURDIR}/buildroot"
mkdir -p $BUILDROOT
DESTIMG="${BUILDROOT}/yosemite_boot.img"
INSTALLESD_IMG="${BUILDROOT}/InstallESD.img"
TMPDIR="$(mktemp -d "${BUILDROOT}/tmp.XXXXXX")"

finish() {
    # Only clean up when something failed.
    if [[ $? -ne 0 ]]; then
        red_echo "Script failed cleaning up\n"
        cleanup
    fi

    # Remove temporary directory.
    if [[ -d $TMPDIR ]]; then
        rm -f $TMPDIR/*
        rmdir $TMPDIR
    fi
}

control_c() {
    red_echo "Caught SIGINT; Clean up and Exit\n"
    cleanup
    exit $?
}

trap finish EXIT
trap control_c SIGINT
trap control_c SIGTERM

green_echo() {
    echo -e "\e[1;32m[S] $SCRIPT: $1\e[0m"
}

red_echo() {
    echo -en "\e[1;31m[E] $SCRIPT: $1\e[0m"
}

kpartx() { # OUTVAR ARG1
    local _outvar=$1

    partition=$(sudo kpartx -av "$2" || true)
    sleep 2

    re='\b(loop[0-9]+)'
    [[ "$partition" =~ $re ]]
    eval $_outvar="${BASH_REMATCH[1]}"
}

kpartd() {
    sudo kpartx -d "$1"
}

prepare() {
    mkdir -p "${BUILDROOT}/install_esd"
    mkdir -p "${BUILDROOT}/yosemite_esd"
    mkdir -p "${BUILDROOT}/yosemite_base"
    mkdir -p "${BUILDROOT}/basesystem"
}

do_mount() {
    echo "Mounting $1 on ${BUILDROOT}/$2"
    sudo mount $1 "${BUILDROOT}/$2"
}

mounted() {
    /usr/bin/env mount | grep $1 > /dev/null
}

cleanup() {
    green_echo "Cleaning up"
    mounted "${BUILDROOT}/yosemite_esd" && sudo umount "${BUILDROOT}/yosemite_esd"
    mounted "${BUILDROOT}/yosemite_base" && sudo umount "${BUILDROOT}/yosemite_base"
    mounted "${BUILDROOT}/basesystem" && sudo umount "${BUILDROOT}/basesystem"

    ( cd . ; kpartd "${DESTIMG}" )

    mounted "${BUILDROOT}/install_esd" && sudo umount "${BUILDROOT}/install_esd"
    kpartd "${INSTALLESD_IMG}"
}

mount_install_esd() {
    mounted install_esd && return

    if [ ! -f "$INSTALLESD_IMG" ]; then
        dmg2img "$INSTALLESD_DMG" "$INSTALLESD_IMG"
    fi

    (
      local partition ;
      kpartx partition "$INSTALLESD_IMG" &&
          do_mount /dev/mapper/${partition}p2 install_esd
    )
}

mount_base() {
    mounted yosemite_base && return

    local partition
    kpartx partition "$DESTIMG"

    do_mount /dev/mapper/${partition}p2 yosemite_base
}

allocate() {
    mounted yosemite_base && return
    fallocate -l 9G "$DESTIMG"
    # use truncate for portability
    # touch "$DESTIMG"
    # truncate --size 9G "$DESTIMG"
    parted -s "$DESTIMG" mklabel gpt
    parted -s "$DESTIMG" mkpart primary fat32 40s 409639s
    parted -s "$DESTIMG" name 1 EFI
    parted -s "$DESTIMG" set 1 boot on
#    parted -s "$DESTIMG" set 1 esp on
    parted -s "$DESTIMG" mkpart primary hfs+ 409640s 9GB
    parted -s "$DESTIMG" name 2 682068D2-49C0-4758-BB95-2666E0AC1E9

    local partition
    kpartx partition "$DESTIMG"

    sudo mkfs.vfat /dev/mapper/${partition}p1
    sudo mkfs.hfsplus /dev/mapper/${partition}p2

    do_mount /dev/mapper/${partition}p1 yosemite_esd
    do_mount /dev/mapper/${partition}p2 yosemite_base

    sudo cp "${ASSETS}/NvVars" "${BUILDROOT}/yosemite_esd"
}

copy_base() {
    dmg2img -i "${BUILDROOT}/install_esd/BaseSystem.dmg" -o "${TMPDIR}/BaseSystem.img"

    (
      local partition ;
      cd "${TMPDIR}" &&
      kpartx partition BaseSystem.img &&
      do_mount /dev/mapper/${partition}p2 basesystem
    )

    green_echo "Copying base"
    sudo sh -c "rsync -a --exclude 'System/Library/User Template/ko.lproj/Library/FontCollections' ${BUILDROOT}/basesystem/. ${BUILDROOT}/yosemite_base/. || true"
    sudo umount "${BUILDROOT}/basesystem"

    ( cd "${TMPDIR}" && kpartd "BaseSystem.img" )
    rm "${TMPDIR}/BaseSystem.img"
}

extract_base() {
    green_echo "Extract ${BUILDROOT}/install_esd/BaseSystem.dmg"
    copy_base
    # hdutil crashes the kernel
    # ( cd "${BUILDROOT}/yosemite_base" ;  sudo hdutil "${BUILDROOT}/install_esd/BaseSystem.dmg" extractall > /dev/null )
    # ( cd "${BUILDROOT}/yosemite_base" ;  sudo 7z x "${BUILDROOT}/install_esd/BaseSystem.dmg" -o"${BUILDROOT}/yosemite_base" > /dev/null ; sudo sh -c 'mv OS\ X\ Base\ System/* .' )

    sudo cp "${BUILDROOT}/install_esd/BaseSystem.dmg" "${BUILDROOT}/yosemite_base"
    sudo cp "${BUILDROOT}/install_esd/BaseSystem.chunklist" "${BUILDROOT}/yosemite_base"
    sudo rm "${BUILDROOT}/yosemite_base/System/Installation/Packages"

    green_echo "Copying installation packages"
    sudo mkdir "${BUILDROOT}/yosemite_base/System/Installation/Packages"
    sudo rsync -a --progress "${BUILDROOT}/install_esd/Packages/." "${BUILDROOT}/yosemite_base/System/Installation/Packages/."
    sudo cp "$ASSETS/Yosemite_Background.png" "${BUILDROOT}/yosemite_base"
    echo 10.10 | sudo tee "${BUILDROOT}/yosemite_base/.LionDiskMaker_OSVersion"
    sudo touch "${BUILDROOT}/yosemite_base/.file"
    sudo cp "$ASSETS/VolumeIcon.icns" "${BUILDROOT}/yosemite_base/.VolumeIcon.icns"
    sudo cp "$ASSETS/DS_Store" "${BUILDROOT}/yosemite_base/.DS_Store"
}

fix_permissions(){
    green_echo "Fixing permissions"
    sudo chown -R root:80 "${BUILDROOT}/yosemite_base/Applications" \
        "${BUILDROOT}/yosemite_base/.file"
    # ok this is a hack don't hate me, 99 is nobody on a few systems
    sudo chown 99:99 "${BUILDROOT}/yosemite_base/Yosemite_Background.png" "${BUILDROOT}/yosemite_base/BaseSystem.dmg" \
        "${BUILDROOT}/yosemite_base/BaseSystem.chunklist" \
        "${BUILDROOT}/yosemite_base/.LionDiskMaker_OSVersion" \
        "${BUILDROOT}/yosemite_base/.VolumeIcon.icns"

    sudo chmod 644 "${BUILDROOT}/yosemite_base/Yosemite_Background.png" \
        "${BUILDROOT}/yosemite_base/BaseSystem.dmg" \
        "${BUILDROOT}/yosemite_base/BaseSystem.chunklist"
    sudo chmod 755 "${BUILDROOT}/yosemite_base/etc/rc.cdrom.local"
    sudo sh -c 'chmod 755 '${BUILDROOT}/yosemite_base/System/Installation/Packages/*pkg''
}

provision() {
    green_echo "Provisioning"
    sudo mkdir -p "${BUILDROOT}/yosemite_base/System/Installation/Packages/Extras"
    sudo cp "$ASSETS/minstallconfig.xml" "${BUILDROOT}/yosemite_base/System/Installation/Packages/Extras"
    sudo cp "$ASSETS/OSInstall.collection" "${BUILDROOT}/yosemite_base/System/Installation/Packages"
    sudo cp "$ASSETS/user-config.pkg" "${BUILDROOT}/yosemite_base/System/Installation/Packages"
    echo "diskutil eraseDisk jhfs+ 'Macintosh HD' GPTFormat disk0" | sudo tee "${BUILDROOT}/yosemite_base/etc/rc.cdrom.local"
}

usage() {
    echo "$SCRIPT [-a|-p|-m|-u] <InstallESD.dmg or Install App directory>\n"
    echo "-a    Run all tasks and leave mounts open."
    echo "-p    Provision base image with auto-install files."
    echo "-m    Mount existing base image directory."
    echo "-u    Clean up mounts."
    exit 1
}

if [[ "$#" -gt 2 ]]; then
    red_echo "Too many arguments.\n"
    usage
fi

if [[ "$#" -eq 1 ]]; then
    PATH_ARG="$1"
else
    PATH_ARG="$2"
fi

INSTALLESD_DMG=""
if [[ -d "$PATH_ARG" ]]; then
    if [[ -f "$PATH_ARG/InstallESD.dmg" ]]; then
        INSTALLESD_DMG="$PATH_ARG/InstallESD.dmg"
    elif [[ -f "$PATH_ARG/Contents/SharedSupport/InstallESD.dmg" ]]; then
        INSTALLESD_DMG="$PATH_ARG/Contents/SharedSupport/InstallESD.dmg"
    fi
elif [[ -f "$PATH_ARG" ]]; then
    INSTALLESD_DMG="$PATH_ARG"
fi

if [[ "$#" -eq 1 && ! -z $INSTALLESD_DMG ]]; then
    prepare
    allocate
    mount_install_esd
    extract_base
    provision
    fix_permissions
    cleanup
    exit 0
fi

while getopts ":autmp" opt; do
    case $opt in
        a)
            if [[ -z "$INSTALLESD_DMG" ]]; then
                red_echo "Can't find InstallESD.dmg\n"
                usage
            fi
            green_echo "Running all tasks" >&2
            prepare
            allocate
            mount_install_esd
            extract_base
            provision
            fix_permissions
            ;;
        p)
            green_echo "Reprovision" >&2
            provision
            fix_permissions
            ;;
        m)
            green_echo "Mount only" >&2
            prepare
            mount_base
            ;;
        u)
            green_echo "Unmount and remove maps" >&2
            cleanup
            ;;
        \?)
            red_echo "Invalid option: -$OPTARG" >&2
            ;;
    esac
done

if [[ $OPTIND -eq 1 ]]; then
    usage
fi
