#!/bin/bash
set -euxo pipefail
grep -q "^DisableSandbox" /etc/pacman.conf || sed -i "s/^\[options\]/[options]\nDisableSandbox/" /etc/pacman.conf
pacman -Syu --noconfirm --needed base-devel git pacman-contrib >/dev/null
useradd -m builder || true
cp -r /in /home/builder/pkg; chown -R builder /home/builder/pkg
cd /home/builder/pkg
su builder -c 'updpkgsums && makepkg --printsrcinfo > .SRCINFO' 
pacman -S --noconfirm --needed $(su builder -c 'source PKGBUILD; echo ${depends[@]} ${makedepends[@]}' | sed "s/>=[0-9]*//g") >/dev/null
su builder -c 'PKGEXT=.pkg.tar.zst makepkg -f --noconfirm' 2>&1 | tail -60
cp betterguac-*.pkg.tar.* PKGBUILD .SRCINFO /out/
namcap betterguac-*.pkg.tar.* 2>/dev/null || true
