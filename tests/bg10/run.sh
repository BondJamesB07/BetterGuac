#!/bin/bash
# usage: run.sh <workdir> <debian|ubuntu> <fresh|upgrade> <new.deb> [old.deb]
# Throwaway systemd container + throwaway RDP/VNC target on a private network.
set -u
W="$1"; OS="$2"; MODE="$3"; NEW="$4"; OLD="${5:-}"; A=$(dpkg --print-architecture 2>/dev/null || (uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/'))
case $OS in debian) BASE=debian:trixie;; ubuntu) BASE=ubuntu:26.04;; esac
SHA=$(sha256sum "$NEW" | cut -d' ' -f1)
IMG=bg10-sysd-$OS; C=bg10-$MODE-$OS-$A; T=bg10-target-$A; NET=bg10-net; TPW=$(head -c 18 /dev/urandom | base64 | tr -dc A-Za-z0-9 | head -c 16)
LOG="$W/logs/$MODE-$OS-$A.log"; mkdir -p "$W/logs"
{
echo "=== $MODE $OS $A $(date -u +%FT%TZ) host=$(hostname) new=$SHA"
D=$(mktemp -d); printf 'FROM %s\nRUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq systemd systemd-sysv curl python3 ca-certificates >/dev/null && apt-get clean\nSTOPSIGNAL SIGRTMIN+3\nCMD ["/sbin/init"]\n' "$BASE" > $D/Dockerfile
docker build -q -t $IMG $D >/dev/null && echo sysd-image-ok; rm -rf $D
docker network inspect $NET >/dev/null 2>&1 || docker network create $NET >/dev/null
docker build -q -t bg10-target -f "$W/Dockerfile.target" "$W" >/dev/null && echo target-image-ok
docker rm -f $C $T >/dev/null 2>&1
docker run -d --name $T --network $NET -e PW="$TPW" bg10-target >/dev/null
EXTRA=""; [ -n "$OLD" ] && EXTRA="-v $OLD:/root/old.deb:ro"
docker run -d --name $C --network $NET --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock \
  -v "$NEW":/root/new.deb:ro $EXTRA $IMG >/dev/null
for f in common.sh probe.py test-incontainer.sh bg10-checks.sh inner-fresh.sh inner-upgrade.sh; do docker cp "$W/$f" $C:/root/$f >/dev/null; done
for i in $(seq 1 30); do docker logs $T 2>&1 | grep -q READY && break; sleep 1; done; echo "target: $(docker logs $T 2>&1 | tail -1)"
for i in $(seq 1 60); do docker exec $C sh -c 'systemctl is-system-running 2>/dev/null | grep -qE "running|degraded"' && break; sleep 2; done
docker exec $C sh -c '. /etc/os-release; echo "os: $PRETTY_NAME arch: $(dpkg --print-architecture)"'
docker exec -e TARGET=$T -e TPW="$TPW" -e EXPECT_SHA=$SHA $C bash /root/inner-$MODE.sh
echo "TEST_RC=$?"
docker rm -f $T $C >/dev/null; echo containers-removed
} > "$LOG" 2>&1
grep -E "^(=== |os:|PASS|FAIL|TEST_RC|before upgrade|after upgrade|session events|history rows|---)" "$LOG"
