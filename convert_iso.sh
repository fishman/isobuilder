#!/bin/bash

## Requirements, dmg2img, aria2, kpartx, hfsprogs, hfsutils, p7zip-full

set -e -uf -o pipefail
shopt -s extglob

SCRIPT=$(basename $0)
CURDIR="$(cd -P "$( dirname "${BASH_SOURCE[0]}" )" && pwd)"
ASSETS="${CURDIR}/assets"
BUILDROOT="${CURDIR}/buildroot"
mkdir -p $BUILDROOT
DESTIMG="${BUILDROOT}/osx_boot.img"
INSTALLESD_IMG="${BUILDROOT}/InstallESD.img"
TMPDIR="$(mktemp -d "${BUILDROOT}/tmp.XXXXXX")"
[[ -z "$OSX_VERSION" ]] && OSX_VERSION="10.10"

green_echo() {
    echo -e "\e[1;32m[S] $SCRIPT: $1\e[0m"
}

red_echo() {
    echo -en "\e[1;31m[E] $SCRIPT: $1\e[0m"
}

if [[ "$(whoami)" != "root" ]]; then
    red_echo "Please use sudo.\n"
    exit 2
fi

finish() {
    # Only clean up when something failed.
    if [[ $? -ne 0 ]]; then
        red_echo "Script failed, cleaning up\n"
        cleanup
    fi

    # Remove temporary directory.
    if [[ -d $TMPDIR ]]; then
        rm -f $TMPDIR/*/*
        rm -f $TMPDIR/*
        rmdir $TMPDIR
    fi
}

control_c() {
    red_echo "Caught SIGINT; cleaning up\n"
    cleanup
    exit $?
}

trap finish EXIT
trap control_c SIGINT
trap control_c SIGTERM

do_kpartx() { # OUTVAR ARG1
    local _outvar=$1

    dn="$(dirname $2)"
    fn="$(basename $2)"
    pushd $dn
    partition=$(kpartx -av "$fn" || true)
    popd

    sleep 2

    re='\b(loop[0-9]+)'
    [[ "$partition" =~ $re ]]
    eval $_outvar="${BASH_REMATCH[1]}"
}

do_kpartx_d() {
    dn="$(dirname $1)"
    fn="$(basename $1)"
    pushd $dn
    kpartx -d "$fn"
    popd
}

prepare() {
    mkdir -p "${BUILDROOT}/install_esd"
    mkdir -p "${BUILDROOT}/osx_esd"
    mkdir -p "${BUILDROOT}/osx_base"
    mkdir -p "${BUILDROOT}/basesystem"
}

do_mount() {
    echo "Mounting $1 on ${BUILDROOT}/$2"
    mount $1 "${BUILDROOT}/$2"
}

mounted() {
    /usr/bin/env mount | grep $1 > /dev/null
}

cleanup() {
    green_echo "Cleaning up"
    mounted "${BUILDROOT}/osx_esd" && umount "${BUILDROOT}/osx_esd"
    mounted "${BUILDROOT}/osx_base" && umount "${BUILDROOT}/osx_base"
    mounted "${BUILDROOT}/basesystem" && umount "${BUILDROOT}/basesystem"

    do_kpartx_d "${DESTIMG}"

    mounted "${BUILDROOT}/install_esd" && umount "${BUILDROOT}/install_esd"
    do_kpartx_d "${INSTALLESD_IMG}"
}

mount_install_esd() {
    mounted install_esd && return

    if [ ! -f "$INSTALLESD_IMG" ]; then
        dmg2img "$INSTALLESD_DMG" "$INSTALLESD_IMG"
    fi

    (
      local partition;
      do_kpartx partition "$INSTALLESD_IMG" &&
          do_mount /dev/mapper/${partition}p2 install_esd
    )
}

mount_base() {
    mounted osx_base && return

    local partition
    do_kpartx partition "$DESTIMG"

    do_mount /dev/mapper/${partition}p2 osx_base
}

allocate() {
    mounted osx_base && return
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
    do_kpartx partition "$DESTIMG"

    mkfs.vfat /dev/mapper/${partition}p1
    mkfs.hfsplus /dev/mapper/${partition}p2

    do_mount /dev/mapper/${partition}p1 osx_esd
    do_mount /dev/mapper/${partition}p2 osx_base

    cp "${ASSETS}/NvVars" "${BUILDROOT}/osx_esd"
}

copy_base() {
    dmg2img -i "${BUILDROOT}/install_esd/BaseSystem.dmg" -o "${TMPDIR}/BaseSystem.img"

    (
      local partition;
      do_kpartx partition "${TMPDIR}/BaseSystem.img" &&
      do_mount /dev/mapper/${partition}p2 basesystem
    )

    green_echo "Copying base"
    sh -c "rsync -a --exclude 'System/Library/User Template/ko.lproj/Library/FontCollections' ${BUILDROOT}/basesystem/. ${BUILDROOT}/osx_base/. || true"
    umount "${BUILDROOT}/basesystem"

    do_kpartx_d "${TMPDIR}/BaseSystem.img"
    rm "${TMPDIR}/BaseSystem.img"
}

extract_base() {
    green_echo "Extract ${BUILDROOT}/install_esd/BaseSystem.dmg"
    copy_base
    # hdutil crashes the kernel
    # ( cd "${BUILDROOT}/osx_base" ;  hdutil "${BUILDROOT}/install_esd/BaseSystem.dmg" extractall > /dev/null )
    # ( cd "${BUILDROOT}/osx_base" ;  7z x "${BUILDROOT}/install_esd/BaseSystem.dmg" -o"${BUILDROOT}/osx_base" > /dev/null ; sh -c 'mv OS\ X\ Base\ System/* .' )

    cp "${BUILDROOT}/install_esd/BaseSystem.dmg" "${BUILDROOT}/osx_base"
    cp "${BUILDROOT}/install_esd/BaseSystem.chunklist" "${BUILDROOT}/osx_base"
    rm "${BUILDROOT}/osx_base/System/Installation/Packages"

    green_echo "Copying installation packages"
    mkdir "${BUILDROOT}/osx_base/System/Installation/Packages"
    rsync -a --progress "${BUILDROOT}/install_esd/Packages/." "${BUILDROOT}/osx_base/System/Installation/Packages/."
    cp "$ASSETS/OSX_Background.png" "${BUILDROOT}/osx_base"
    echo $OSX_VERSION | tee "${BUILDROOT}/osx_base/.LionDiskMaker_OSVersion"
    touch "${BUILDROOT}/osx_base/.file"
    cp "$ASSETS/VolumeIcon.icns" "${BUILDROOT}/osx_base/.VolumeIcon.icns"
    cp "$ASSETS/DS_Store" "${BUILDROOT}/osx_base/.DS_Store"
}

fix_permissions(){
    green_echo "Fixing permissions"
    chown -R root:80 "${BUILDROOT}/osx_base/Applications" \
        "${BUILDROOT}/osx_base/.file"
    # ok this is a hack don't hate me, 99 is nobody on a few systems
    chown 99:99 "${BUILDROOT}/osx_base/OSX_Background.png" "${BUILDROOT}/osx_base/BaseSystem.dmg" \
        "${BUILDROOT}/osx_base/BaseSystem.chunklist" \
        "${BUILDROOT}/osx_base/.LionDiskMaker_OSVersion" \
        "${BUILDROOT}/osx_base/.VolumeIcon.icns"

    chmod 644 "${BUILDROOT}/osx_base/OSX_Background.png" \
        "${BUILDROOT}/osx_base/BaseSystem.dmg" \
        "${BUILDROOT}/osx_base/BaseSystem.chunklist"
    chmod 755 "${BUILDROOT}/osx_base/etc/rc.cdrom.local"
    sh -c 'chmod 755 '${BUILDROOT}/osx_base/System/Installation/Packages/*pkg''
}

provision() {
    green_echo "Provisioning"
    mkdir -p "${BUILDROOT}/osx_base/System/Installation/Packages/Extras"
    cp "$ASSETS/minstallconfig.xml" "${BUILDROOT}/osx_base/System/Installation/Packages/Extras"
    cp "$ASSETS/OSInstall.collection" "${BUILDROOT}/osx_base/System/Installation/Packages"
    cp "$ASSETS/user-config.pkg" "${BUILDROOT}/osx_base/System/Installation/Packages"
    echo "diskutil eraseDisk jhfs+ 'Macintosh HD' GPTFormat disk0" | tee "${BUILDROOT}/osx_base/etc/rc.cdrom.local"
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
