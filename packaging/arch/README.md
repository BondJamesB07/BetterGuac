# Arch Linux package

`PKGBUILD` builds `betterguac-1.6.0+bg10-3-<arch>.pkg.tar.zst` for x86_64 and
aarch64 from the `v1.6.0-bg10` tag, the Apache Guacamole 1.6.0 release
archives, MariaDB Connector/J 2.7.15 and the Apache Tomcat migration tool
1.0.13 (the last two are not packaged by Arch and ship unmodified, with their
licenses and source pointers in `SOURCES.arch`).

On Arch Linux or Arch Linux ARM:

    makepkg -si

In a clean container (what the release builds used):

    docker run --rm -v $PWD:/in:ro -v $PWD/out:/out archlinux:base-devel bash /in/build-in-container.sh
    # aarch64: menci/archlinuxarm:base-devel on an arm64 host

Tests: `tests/arch/run.sh <package> <base image> <tag>` installs the package in
a fresh systemd container and runs the shared bg10 checks plus SSH, RDP and VNC
sessions, reinstall and removal.

RHEL, Rocky, Alma and CentOS have no package: use the Docker image.
