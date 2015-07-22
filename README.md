# isobuilder
isobuilder allows you to convert images into a format that works as an installer for qemu

    sudo ./convert_iso.sh /tmp/Install\ OS\ X\ 10.11\ Developer\ Beta.app/Contents/SharedSupport/InstallESD.dmg 

# requirements

    sudo apt-get install parted kpartx dmg2img hfsutils dosfstools
