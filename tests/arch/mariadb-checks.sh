#!/bin/bash
# MariaDB checks on a fresh install of the Arch package, in a systemd container,
# with a second container on the same network as the "other machine".
# usage: mariadb-checks.sh <pkg> <arch-base-image> <tag>
set -u
PKG=$(readlink -f "$1"); BASE=$2; TAG=$3
SRC=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d /tmp/bgarch-mdb.XXXXXX); cp "$SRC"/Dockerfile "$D"/
IMG=bgarch-test-$TAG; NET=bgarch-mdbnet-$TAG; C=bgarch-mdb-$TAG; PEER=bgarch-mdbpeer-$TAG
PASS=0; FAIL=0
pass(){ echo "PASS: $*"; PASS=$((PASS+1)); }
fail(){ echo "FAIL: $*"; FAIL=$((FAIL+1)); }
docker build -q --build-arg BASE="$BASE" -t $IMG "$D" >/dev/null || { echo "FAIL test image"; exit 1; }
docker rm -f $C $PEER >/dev/null 2>&1; docker network rm $NET >/dev/null 2>&1; docker network create $NET >/dev/null
docker run -d --name $C --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /tmp --network $NET -v "$PKG":/pkg/$(basename "$PKG"):ro $IMG >/dev/null
docker run -d --name $PEER --network $NET $IMG sleep infinity >/dev/null
x(){ docker exec $C bash -c "$1"; }
for i in $(seq 60); do x 'systemctl is-system-running' 2>/dev/null | grep -qE 'running|degraded' && break; sleep 1; done
x "pacman -Sy >/dev/null 2>&1; pacman -U --noconfirm /pkg/$(basename "$PKG") >/dev/null 2>&1" && pass "fresh install of $(basename "$PKG")" || fail "install"
x 'for i in $(seq 90); do [ "$(curl -s -o /dev/null -w %{http_code} --max-time 5 http://127.0.0.1:8080/betterguac/)" = 200 ] && exit 0; sleep 2; done; exit 1'
L=$(x "ss -ltnH | awk '{print \$4}' | grep ':3306\$' | tr '\n' ' '")
[ "$(echo $L)" = 127.0.0.1:3306 ] && pass "MariaDB listens on 127.0.0.1:3306 only" || fail "MariaDB listens on [$L]"
N=$(x "mariadb --protocol=socket -uroot -N -B -e \"SELECT COUNT(*) FROM mysql.global_priv WHERE User=''\"")
[ "$N" = 0 ] && pass "no anonymous accounts" || fail "$N anonymous accounts"
N=$(x "mariadb --protocol=socket -uroot -N -B -e \"SHOW DATABASES LIKE 'test'\"")
[ -z "$N" ] && pass "no test database" || fail "test database exists"
x 'id nobody >/dev/null && su -s /bin/bash nobody -c "mariadb --protocol=socket -e \"SELECT 1\"" >/dev/null 2>&1' && fail "an unprivileged local user signs in anonymously" || pass "an unprivileged local user cannot sign in anonymously"
P=$(docker exec $PEER bash -c "timeout 5 bash -c '</dev/tcp/$C/3306' 2>/dev/null && echo open || echo refused")
[ "$P" = refused ] && pass "port 3306 refused from another container" || fail "port 3306 $P from another container"
W=$(docker exec $PEER bash -c "timeout 5 bash -c '</dev/tcp/$C/8080' 2>/dev/null && echo open || echo refused")
[ "$W" = open ] && pass "port 8080 answers from another container" || fail "port 8080 $W from another container"
docker rm -f $C $PEER >/dev/null 2>&1; docker network rm $NET >/dev/null 2>&1; rm -rf "$D"
echo "=== MARIADB RESULT $TAG pass=$PASS fail=$FAIL ==="
[ "$FAIL" = 0 ]
