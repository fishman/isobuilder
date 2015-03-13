#!/bin/bash

## Requirements, dmg2iso, aria2c, kpartx, hfsutils, 7z

set -uf -o pipefail
# set -e
shopt -s extglob

BASE=/home/timebomb/git/osx/isobuilder
# BASE=/media/Untitled
# BASE=/run/media/timebomb/Untitled

EXT4=1
TMP="$(mktemp -d)"
INSTALL_FOLDER="Install OS X Yosemite.app/Contents/SharedSupport"
INSTALL_IMG="InstallESD.dmg"
DESTIMG="yosemite_boot.img"
MOUNTTMP="/tmp/buildroot"
RUNDIR="${PWD}"
ASSETS="${RUNDIR}/assets"

function control_c {
    echo -en "\n## Caught SIGINT; Clean up and Exit \n"
    rm ${TMP}/*
    cleanup
    exit $?
}

trap control_c SIGINT
trap control_c SIGTERM

kpartx () { # OUTVAR ARG1
    local _outvar=$1

    partition=$(sudo kpartx -av "$2")

    re='\b(loop[0-9]+)'
    [[ "$partition" =~ $re ]]
    eval $_outvar="${BASH_REMATCH[1]}"
}

kpartd () {
    sudo kpartx -d "$1"
}

prepare () {
    mkdir -p "${MOUNTTMP}/install_esd"
    mkdir -p "${MOUNTTMP}/yosemite_esd"
    mkdir -p "${MOUNTTMP}/yosemite_base"
    mkdir -p "${MOUNTTMP}/basesystem"
}

mount () {
    echo "$1 ${MOUNTTMP}/$2"
    sudo mount $1 "${MOUNTTMP}/$2"
}

mounted () {
    /usr/bin/env mount | grep $1 > /dev/null
}


cleanup () {
    mounted "${MOUNTTMP}/yosemite_esd" && sudo umount "${MOUNTTMP}/yosemite_esd"
    mounted "${MOUNTTMP}/yosemite_base" && sudo umount "${MOUNTTMP}/yosemite_base"

    ( cd . ; kpartd "${DESTIMG}" )


    if [ -d "${BASE}" ]; then
        mounted "${MOUNTTMP}/install_esd" && sudo umount "${MOUNTTMP}/install_esd"
        kpartd "${BASE}/${INSTALL_FOLDER}/${INSTALL_IMG//dmg/img}"
        ( cd "${BASE}/${INSTALL_FOLDER}" ; kpartd "${INSTALL_IMG//dmg/img}" )
    fi
}

mount_install_esd () {
    mounted install_esd && return
    # dmg iso "${INSTALL_ESD}" "${INSTALL_ESD//dmg/iso}"
    local partition
    kpartx partition "${BASE}/${INSTALL_FOLDER}/${INSTALL_IMG//dmg/img}"
    # dmg2img "${INSTALL_IMG}"
    mount /dev/mapper/${partition}p2 install_esd
}

mount_base () {
    mounted yosemite_base && return

    local partition
    kpartx partition "$DESTIMG"
    sleep 4

    mount /dev/mapper/${partition}p2 yosemite_base
}

allocate () {
    mounted yosemite_base && return
    fallocate -l 9G "$DESTIMG"
    # use truncate for portability
    # touch "$DESTIMG"
    # truncate --size 9G "$DESTIMG"
    parted -s "$DESTIMG" mklabel gpt
    parted -s "$DESTIMG" mkpart primary fat32 40s 409639s
    parted -s "$DESTIMG" name 1 EFI
    parted -s "$DESTIMG" set 1 boot on
    parted -s "$DESTIMG" set 1 esp on
    parted -s "$DESTIMG" mkpart primary hfs+ 409640s 9GB
    parted -s "$DESTIMG" name 2 682068D2-49C0-4758-BB95-2666E0AC1E9

    local partition
    kpartx partition "$DESTIMG"
    sleep 4

    sudo mkfs.vfat /dev/mapper/${partition}p1
    sudo mkfs.hfsplus /dev/mapper/${partition}p2
    
    mount /dev/mapper/${partition}p1 yosemite_esd
    mount /dev/mapper/${partition}p2 yosemite_base

    sudo cp "${ASSETS}/NvVars" "${MOUNTTMP}/yosemite_esd"
}


copy_base () {
    echo "${MOUNTTMP}/install_esd/BaseSystem.dmg"
    dmg2img -i "${MOUNTTMP}/install_esd/BaseSystem.dmg" -o "${TMP}/BaseSystem.img"

    local partition
    kpartx partition "${TMP}/BaseSystem.img"
    mount /dev/mapper/${partition}p2 basesystem
    sudo sh -c "cp -a ${MOUNTTMP}/basesystem/* ${MOUNTTMP}/yosemite_base"
    sudo umount "${MOUNTTMP}/basesystem"

    kpartd "${TMP}/BaseSystem.img"
    rm "${TMP}/BaseSystem.img"
}

extract_base () {
    echo "${MOUNTTMP}/install_esd/BaseSystem.dmg"
    copy_base
    # hdutil crashes the kernel
    # ( cd "${MOUNTTMP}/yosemite_base" ;  sudo hdutil "${MOUNTTMP}/install_esd/BaseSystem.dmg" extractall > /dev/null )
    # ( cd "${MOUNTTMP}/yosemite_base" ;  sudo 7z x "${MOUNTTMP}/install_esd/BaseSystem.dmg" -o"${MOUNTTMP}/yosemite_base" > /dev/null ; sudo sh -c 'mv OS\ X\ Base\ System/* .' )

    sudo cp "${MOUNTTMP}/install_esd/BaseSystem.dmg" "${MOUNTTMP}/yosemite_base"
    sudo cp "${MOUNTTMP}/install_esd/BaseSystem.chunklist" "${MOUNTTMP}/yosemite_base"
    sudo rm "${MOUNTTMP}/yosemite_base/System/Installation/Packages"
    sudo cp -a "${MOUNTTMP}/install_esd/Packages" "${MOUNTTMP}/yosemite_base/System/Installation"
    sudo cp "$ASSETS/Yosemite_Background.png" "${MOUNTTMP}/yosemite_base"
    echo 10.10 | sudo tee "${MOUNTTMP}/yosemite_base/.LionDiskMaker_OSVersion"
    sudo touch "${MOUNTTMP}/yosemite_base/.file"
    sudo cp "$ASSETS/VolumeIcon.icns" "${MOUNTTMP}/yosemite_base/.VolumeIcon.icns"
    sudo cp "$ASSETS/DS_Store" "${MOUNTTMP}/yosemite_base/.DS_Store"
}

fix_permissions (){
    sudo chown -R root:80 "${MOUNTTMP}/yosemite_base/Applications" \
        "${MOUNTTMP}/yosemite_base/.file"
    # ok this is a hack don't hate me
    sudo chown nobody:nobody "${MOUNTTMP}/yosemite_base/Yosemite_Background.png" "${MOUNTTMP}/yosemite_base/BaseSystem.dmg" \
        "${MOUNTTMP}/yosemite_base/BaseSystem.chunklist" \
        "${MOUNTTMP}/yosemite_base/.LionDiskMaker_OSVersion" \
        "${MOUNTTMP}/yosemite_base/.VolumeIcon.icns"

    sudo chmod 644 "${MOUNTTMP}/yosemite_base/Yosemite_Background.png" \
        "${MOUNTTMP}/yosemite_base/BaseSystem.dmg" \
        "${MOUNTTMP}/yosemite_base/BaseSystem.chunklist"
    sudo chmod 755 "${MOUNTTMP}/yosemite_base/etc/rc.cdrom.local"
    sudo sh -c 'chmod 755 '${MOUNTTMP}/yosemite_base/System/Installation/Packages/*pkg''
}

provision () {
    sudo mkdir -p "${MOUNTTMP}/yosemite_base/System/Installation/Packages/Extras"
    sudo cp "$ASSETS/minstallconfig.xml" "${MOUNTTMP}/yosemite_base/System/Installation/Packages/Extras"
    sudo cp "$ASSETS/OSInstall.collection" "${MOUNTTMP}/yosemite_base/System/Installation/Packages"
    sudo cp "$ASSETS/user-config.pkg" "${MOUNTTMP}/yosemite_base/System/Installation/Packages"
    echo "diskutil eraseDisk jhfs+ 'Macintosh HD' GPTFormat disk0" | sudo tee "${MOUNTTMP}/yosemite_base/etc/rc.cdrom.local"
}

get_commandline_tools () {
    link="/Developer_Tools/Command_Line_Tools_OS_X_10.10_for_Xcode__Xcode_6.2/commandlinetoolsosx10.10forxcode6.2.dmg"

    (
        cd "${TMP}" ; "${RUNDIR}/get_tools.sh" ${link} ; \
        7z x commandlinetoolsosx10.10forxcode6.2.dmg ; \
        sudo mv 'Command Line Developer Tools/Command Line Tools (OS X 10.10).pkg' "${MOUNTTMP}/yosemite_base/System/Installation/Packages/commandlinetools.pkg" ; \
        rm -rf 'Command Line Developer Tools' commandline*
    )


}

while getopts ":autmp" opt; do
    case $opt in
        a)
            echo "Run all tasks" >&2
            prepare
            allocate
            mount_install_esd
            extract_base
            provision
            get_commandline_tools
            fix_permissions
            cleanup
            ;;

        p)
            echo "Reprovision" >&2
            provision
            fix_permissions
            ;;
        m)
            echo "Mount only" >&2
            mount_base
            ;;
        u)
            echo "Unmount and remove maps" >&2
            cleanup
            ;;

        t)
            echo "Get commandline tools" >&2
            mount_base
            get_commandline_tools
            fix_permissions
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            ;;
    esac
done
