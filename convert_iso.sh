#!/bin/bash

set -uf -o pipefail
# set -e
shopt -s extglob

BASE=/home/timebomb/git/osx/isobuilder
# BASE=/media/Untitled
# BASE=/run/media/timebomb/Untitled

EXT4=1
TMP="tmp"
INSTALL_FOLDER="Install OS X Yosemite.app/Contents/SharedSupport"
INSTALL_IMG="InstallESD.dmg"
DESTIMG="yosemite_boot.img"
MOUNTTMP="/tmp/buildroot"
RUNDIR="${PWD}"
ASSETS="${RUNDIR}/assets"

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
}

mount () {
    echo "$1 ${MOUNTTMP}/$2"
    sudo mount $1 "${MOUNTTMP}/$2"
}

mounted () {
    /usr/bin/mount | grep $1 > /dev/null
}


cleanup () {
    mounted "${MOUNTTMP}/yosemite_esd" && sudo umount "${MOUNTTMP}/yosemite_esd"
    mounted "${MOUNTTMP}/yosemite_base" && sudo umount "${MOUNTTMP}/yosemite_base"

    ( cd . ; kpartd "${DESTIMG}" )


    if [ -d "${BASE}" ]; then
        mounted "${MOUNTTMP}/install_esd" && sudo umount "${MOUNTTMP}/install_esd"
        ( cd "${BASE}/${INSTALL_FOLDER}" ; kpartd "${INSTALL_IMG//dmg/img}" )
    fi
}

mount_install_esd () {
    mounted install_esd && return
    # dmg iso "${INSTALL_ESD}" "${INSTALL_ESD//dmg/iso}"
    local partition
    ( cd "${BASE}/${INSTALL_FOLDER}";  kpartx partition "${INSTALL_IMG//dmg/img}" )
    # dmg2img "${INSTALL_IMG}"
    mount /dev/mapper/${partition}p2 install_esd
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

extract_base () {
    echo "${MOUNTTMP}/install_esd/BaseSystem.dmg"
    # hdutil crashes the kernel
    # ( cd "${MOUNTTMP}/yosemite_base" ;  sudo hdutil "${MOUNTTMP}/install_esd/BaseSystem.dmg" extractall > /dev/null )
    ( cd "${MOUNTTMP}/yosemite_base" ;  sudo 7z x "${MOUNTTMP}/install_esd/BaseSystem.dmg" -o"${MOUNTTMP}/yosemite_base" > /dev/null ; sudo sh -c 'mv OS\ X\ Base\ System/* .' )
    sudo "$RUNDIR/fix_symlinks.sh" "${MOUNTTMP}/yosemite_base"

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
    sudo chmod go+r -R "${MOUNTTMP}/yosemite_base"
    sudo chown -R root:80 "${MOUNTTMP}/yosemite_base/Applications" "${MOUNTTMP}/yosemite_base/Volumes" \
        "${MOUNTTMP}/yosemite_base/.file"
    # ok this is a hack don't hate me
    sudo chmod 755 -R "${MOUNTTMP}/yosemite_base/"
    sudo chmod 600 -R "${MOUNTTMP}/yosemite_base/etc/master.passwd" "${MOUNTTMP}/yosemite_base/.file"
    sudo chown nobody:nobody "${MOUNTTMP}/yosemite_base/Yosemite_Background.png" "${MOUNTTMP}/yosemite_base/BaseSystem.dmg" \
        "${MOUNTTMP}/yosemite_base/BaseSystem.chunklist" \
        "${MOUNTTMP}/yosemite_base/.LionDiskMaker_OSVersion" \
        "${MOUNTTMP}/yosemite_base/.VolumeIcon.icns"

    sudo chmod 644 "${MOUNTTMP}/yosemite_base/Yosemite_Background.png" "${MOUNTTMP}/yosemite_base/BaseSystem.dmg" "${MOUNTTMP}/yosemite_base/BaseSystem.chunklist"
}

provision () {
    sudo mkdir -p "${MOUNTTMP}/yosemite_base/System/Installation/Packages/Extras"
    # sudo cp "$ASSETS/minstallconfig.xml" "${MOUNTTMP}/yosemite_base/System/Installation/Packages/Extras"
    echo "diskutil eraseDisk jhfs+ "Macintosh HD" GPTFormat disk1" | sudo tee "${MOUNTTMP}/yosemite_base/etc/rc.cdrom.local"
    sudo chmod 755 "${MOUNTTMP}/yosemite_base/etc/rc.cdrom.local"
}

prepare
# cleanup
allocate
mount_install_esd
extract_base
fix_permissions
provision
# cleanup
