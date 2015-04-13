#!/usr/bin/env bash

curdir=$(dirname 0)

declare packageid="com.saucelabs.userconfig"
declare packagename="userconfig"

prepare() {
    mkdir -p build
    mkdir -p flat/base.pkg flat/Resources/en.lproj
    mkdir -p scripts
}

create_package_info() {
    declare count="$(find root | wc -l)"
    declare size="$(du -b -k -s root | cut -f1)"

    eval "echo \"$(< tpl/packageinfo.xml)\"" > flat/base.pkg/PackageInfo
}

pack() {
    ( cd root && find . | cpio -o --format odc --owner 0:80 | gzip -c ) > flat/base.pkg/Payload
    ( cd scripts && find . | cpio -o --format odc --owner 0:80 | gzip -c ) > flat/base.pkg/Scripts
    mkbom -u 0 -g 80 root flat/base.pkg/Bom
}

create_distribution() {
    declare size="$(du -b -k -s root | cut -f1)"

    eval "echo \"$(< tpl/distribution.xml)\"" > flat/Distribution
}

create_package() {
    ( cd flat && xar --compression none -cf "../${packageid}.pkg" * )
}

prepare
pack
create_package_info
create_distribution
create_package
