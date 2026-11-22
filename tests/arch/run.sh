#!/bin/bash
# Arch package test in fresh systemd containers.
# usage: run.sh <pkgfile> <arch-base-image> <tag>
#   x86_64:  run.sh betterguac-...-x86_64.pkg.tar.zst  archlinux:base        x86
#   aarch64: run.sh betterguac-...-aarch64.pkg.tar.zst menci/archlinuxarm:base arm
set -u
PKG=$(readlink -f "$1"); BASE=$2; TAG=$3
SRC=$(cd "$(dirname "$0")" && pwd)
# work folder: these files plus the shared checks from tests/bg10, adapted for pacman
D=$(mktemp -d /tmp/bgarch-test.XXXXXX)
cp "$SRC"/Dockerfile "$SRC"/inner.sh "$SRC"/expect.env "$D"/
for f in common.sh bg10-checks.sh test-incontainer.sh probe.py Dockerfile.target target-entry.sh; do cp "$SRC/../bg10/$f" "$D/"; done
sed -i "s#/root/probe.py#./probe.py#g" "$D/common.sh"
sed -i "s#V=\$(dpkg-query -W -f='\${Version}' betterguac)#V=\$(pacman -Q betterguac | cut -d' ' -f2)#; s#\[ \"\$V\" = \"1.6.0+bg10\" \]#[ \"\$V\" = \"${BG_EXPECT_VER:-1.6.0+bg10-2}\" ]#" "$D/bg10-checks.sh"
IMG=bgarch-test-$TAG; C=bgarch-t-$TAG; S=bgarch-ssh-$TAG; T=bgarch-rdp-$TAG; NET=bgarch-net-$TAG
TPW=$(head -c 18 /dev/urandom | base64 | tr -dc A-Za-z0-9 | head -c 16)
docker rm -f $C $S $T >/dev/null 2>&1; docker network rm $NET >/dev/null 2>&1
docker build -q --build-arg BASE="$BASE" -t $IMG "$D" >/dev/null || { echo "FAIL test image"; exit 1; }
docker build -q -f "$D/Dockerfile.target" -t bgarch-target "$D" >/dev/null || echo "WARN no RDP/VNC target image"
docker network create $NET >/dev/null
rm -rf "$D/ssh"; mkdir -p "$D/ssh"
docker run --rm -v "$D/ssh":/k $IMG sh -c "ssh-keygen -q -t ed25519 -N '' -f /k/id_ed25519 -C bgarch-test; chmod 644 /k/*; chown -R $(id -u):$(id -g) /k"
RUNOPTS="--privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /tmp --network $NET"
docker run -d --name $S $RUNOPTS --network-alias sshtarget -v "$D/ssh":/k:ro $IMG >/dev/null
docker run -d --name $T --network $NET -e PW="$TPW" bgarch-target >/dev/null 2>&1
docker run -d --name $C $RUNOPTS -v "$D":/t:ro -v "$PKG":/pkg/$(basename "$PKG"):ro $IMG >/dev/null
for i in $(seq 60); do docker exec $S systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded' && break; sleep 1; done
docker exec $S bash -c 'ssh-keygen -A >/dev/null; useradd -m tester; install -d -m700 -o tester -g tester /home/tester/.ssh; install -m600 -o tester -g tester /k/id_ed25519.pub /home/tester/.ssh/authorized_keys; systemctl start sshd; systemctl is-active sshd'
for i in $(seq 60); do docker exec $C systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded' && break; sleep 1; done
MJC_SHA=$(sed -n 's/^MJC_SHA=//p' "$D/expect.env")
docker exec -e PKG=/pkg/$(basename "$PKG") -e TARGET=$T -e TPW="$TPW" -e SSHT=sshtarget -e MJC_SHA="$MJC_SHA" $C bash /t/inner.sh
rc=$?
echo "RESULT $TAG rc=$rc"
[ "${KEEP:-0}" = 1 ] || { docker rm -f $C $S $T >/dev/null 2>&1; docker network rm $NET >/dev/null 2>&1; }
rm -rf "$D"
exit $rc
