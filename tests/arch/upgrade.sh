#!/bin/bash
# Arch package upgrade checks for the MariaDB that bg10-1 left open, in fresh
# systemd containers.
# usage: upgrade.sh <bg10-1 pkg> <bg10-2 pkg> <bg10-3 pkg> <arch-base-image> <tag>
#   A: bg10-1 (it initialises MariaDB, open) -> bg10-3: closed, data unchanged;
#      bg10-3 again, and again without its record file: nothing changes
#   B: bg10-1 -> bg10-2 (still open) -> bg10-3: closed
#   C: MariaDB set up by hand first, then bg10-1 -> bg10-3: left as it was
set -u
P1=$(readlink -f "$1"); P2=$(readlink -f "$2"); P3=$(readlink -f "$3"); BASE=$4; TAG=$5
SRC=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d /tmp/bgarch-upg.XXXXXX); cp "$SRC"/Dockerfile "$D"/
IMG=bgarch-test-$TAG; NET=bgarch-upnet-$TAG; PEER=bgarch-uppeer-$TAG
PASS=0; FAIL=0
pass(){ echo "PASS: $*"; PASS=$((PASS+1)); }
fail(){ echo "FAIL: $*"; FAIL=$((FAIL+1)); }
docker build -q --build-arg BASE="$BASE" -t $IMG "$D" >/dev/null || { echo "FAIL test image"; exit 1; }
docker network rm $NET >/dev/null 2>&1; docker network create $NET >/dev/null
RUNOPTS="--privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /tmp --network $NET"
docker rm -f $PEER >/dev/null 2>&1; docker run -d --name $PEER --network $NET $IMG sleep infinity >/dev/null

x(){ docker exec "$C" bash -c "$1"; }
sqlc(){ x "mariadb --protocol=socket -uroot -N -B -e \"$1\""; }
port(){ docker exec $PEER bash -c "timeout 5 bash -c '</dev/tcp/$C/$1' 2>/dev/null && echo open || echo refused"; }
inst(){ docker exec $C pacman -U --noconfirm /pkg/$(basename "$1") > "$D/$C.$2.log" 2>&1 && x 'for i in $(seq 90); do [ "$(curl -s -o /dev/null -w %{http_code} --max-time 5 http://127.0.0.1:8080/betterguac/)" = 200 ] && exit 0; sleep 2; done; exit 1'; }
anon(){ sqlc "SELECT COUNT(*) FROM mysql.global_priv WHERE User=''"; }
testdb(){ sqlc "SHOW DATABASES LIKE 'test'" | grep -c test; }
listen(){ x "ss -ltnH | awk '{print \$4}' | grep ':3306\$' | tr '\n' ' '"; }
# BetterGuac data: row counts plus a dump of both databases without dates.
# Sign-in history and the audit log are left out: sign-ins, and the sign-outs
# a Tomcat restart causes, add rows to them.
data(){ x "for t in guacamole_user guacamole_connection guacamole_connection_history guacamole_user_permission guacamole_connection_permission; do echo -n \$t=; mariadb --protocol=socket -uroot -N -B betterguac -e \"SELECT COUNT(*) FROM \$t\"; done | tr '\n' ' '; mariadb-dump --protocol=socket -uroot --skip-dump-date --databases betterguac betterguac_yamlsync --ignore-table=betterguac.bg_audit_event --ignore-table=betterguac.guacamole_user_history 2>/dev/null | sha256sum | cut -c1-16; sha256sum /etc/betterguac/guacamole.properties /etc/betterguac/sync.env /etc/betterguac/betterguac.yaml /etc/betterguac/initial-admin.txt | sha256sum | cut -c1-16"; }
signin(){ x 'U=$(sed -n "s/^username: //p" /etc/betterguac/initial-admin.txt); P=$(sed -n "s/^password: //p" /etc/betterguac/initial-admin.txt); curl -s -X POST http://127.0.0.1:8080/betterguac/api/tokens --data-urlencode "username=$U" --data-urlencode "password=$P" | grep -c authToken'; }
is_open(){ # label
  local a t l p w; a=$(anon); t=$(testdb); l=$(listen); p=$(port 3306); w=$(port 8080)
  echo "    $1: anonymous=$a test=$t listen=[$l] peer:3306=$p peer:8080=$w"
  [ "$a" -gt 0 ] && [ "$t" = 1 ] && [ "$p" = open ]
}
is_closed(){ # label
  local a t l p w; a=$(anon); t=$(testdb); l=$(listen); p=$(port 3306); w=$(port 8080)
  echo "    $1: anonymous=$a test=$t listen=[$l] peer:3306=$p peer:8080=$w"
  [ "$a" = 0 ] && [ "$t" = 0 ] && [ "$p" = refused ] && [ "$w" = open ] && [ "$(echo $l)" = 127.0.0.1:3306 ]
}
newc(){ C=bgarch-up$1-$TAG; docker rm -f $C >/dev/null 2>&1
  docker run -d --name $C $RUNOPTS -v "$P1":/pkg/$(basename "$P1"):ro -v "$P2":/pkg/$(basename "$P2"):ro -v "$P3":/pkg/$(basename "$P3"):ro $IMG >/dev/null
  for i in $(seq 60); do docker exec $C systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded' && break; sleep 1; done
  x 'pacman -Sy >/dev/null 2>&1'; }
closed_ok(){ # label before-data
  is_closed "$1" && pass "$1: MariaDB closed (no anonymous accounts, no test database, 127.0.0.1 only, peer refused on 3306, 8080 answers)" || fail "$1: MariaDB not closed"
  local d; d=$(data); [ "$d" = "$2" ] && pass "$1: BetterGuac data and settings unchanged ($d)" || fail "$1: data changed: $2 -> $d"
  [ "$(signin)" = 1 ] && pass "$1: setup admin signs in" || fail "$1: sign-in"
  B0=$(data)  # the sign-in adds history and audit rows; later checks compare against this
  x 'systemctl is-active --quiet mariadb tomcat10 betterguac-guacd' && pass "$1: mariadb, tomcat10, guacd active" || fail "$1: services"
  x 'grep -q "^bind-address=127.0.0.1" /etc/my.cnf.d/betterguac-local.cnf && test -s /var/lib/betterguac/mariadb-closed-by-package' && pass "$1: betterguac-local.cnf and the record file written" || fail "$1: cnf/record file"
}

echo "--- A: bg10-1 -> bg10-3"
newc a
inst "$P1" 1 && pass "A: bg10-1 installed" || fail "A: bg10-1 install"
x 'grep -c "ALPM-SCRIPTLET\] betterguac: initialising MariaDB" /var/log/pacman.log' | grep -qx 1 && pass "A: pacman.log has bg10-1's MariaDB init line" || fail "A: no init line in pacman.log"
is_open "A after bg10-1" && pass "A: bg10-1 left MariaDB open (the bug)" || fail "A: bg10-1 state not open, test proves nothing"
B0=$(data)
inst "$P3" 3 && pass "A: upgrade to bg10-3" || fail "A: upgrade to bg10-3"
grep 'betterguac:' "$D/$C.3.log" | sed 's/^/    /'
closed_ok "A after bg10-3" "$B0"
M0=$(x 'systemctl show -p MainPID --value mariadb'); S0=$(x 'sha256sum /var/lib/betterguac/mariadb-closed-by-package')
inst "$P3" 3b && pass "A: bg10-3 over itself" || fail "A: bg10-3 over itself"
{ [ "$(x 'systemctl show -p MainPID --value mariadb')" = "$M0" ] && [ "$(x 'sha256sum /var/lib/betterguac/mariadb-closed-by-package')" = "$S0" ] && ! grep -q 'closed the MariaDB' "$D/$C.3b.log"; } && pass "A: second run did nothing (record file kept, MariaDB not restarted)" || fail "A: second run changed something"
closed_ok "A after bg10-3 again" "$B0"
x 'rm /var/lib/betterguac/mariadb-closed-by-package'
inst "$P3" 3c && pass "A: bg10-3 again without the record file (already closed box)" || fail "A: run 3"
grep 'betterguac:' "$D/$C.3c.log" | sed 's/^/    /'
{ [ "$(x 'systemctl show -p MainPID --value mariadb')" = "$M0" ] && grep -q 'it was already closed' "$D/$C.3c.log"; } && pass "A: on an already closed MariaDB it changes nothing and does not restart it" || fail "A: already-closed run"
closed_ok "A after already-closed run" "$B0"
docker restart $C >/dev/null; for i in $(seq 60); do docker exec $C systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded' && break; sleep 1; done
x 'for i in $(seq 90); do [ "$(curl -s -o /dev/null -w %{http_code} --max-time 5 http://127.0.0.1:8080/betterguac/)" = 200 ] && exit 0; sleep 2; done; exit 1'
closed_ok "A after container restart" "$B0"
[ "${KEEP:-0}" = 1 ] || docker rm -f $C >/dev/null

echo "--- B: bg10-1 -> bg10-2 -> bg10-3"
newc b
inst "$P1" 1 && pass "B: bg10-1 installed" || fail "B: bg10-1 install"
B0=$(data)
inst "$P2" 2 && pass "B: upgrade to bg10-2" || fail "B: upgrade to bg10-2"
is_open "B after bg10-2" && pass "B: bg10-2 upgrade left MariaDB open (as documented)" || fail "B: not open after bg10-2"
inst "$P3" 3 && pass "B: upgrade bg10-2 -> bg10-3" || fail "B: upgrade to bg10-3"
grep 'betterguac:' "$D/$C.3.log" | sed 's/^/    /'
closed_ok "B after bg10-3" "$B0"
[ "${KEEP:-0}" = 1 ] || docker rm -f $C >/dev/null

echo "--- C: MariaDB set up by hand, then bg10-1 -> bg10-3"
newc c
x 'pacman -S --noconfirm mariadb >/dev/null 2>&1 && mariadb-install-db --user=mysql --basedir=/usr --datadir=/var/lib/mysql >/dev/null 2>&1 && systemctl enable --now mariadb >/dev/null 2>&1' && pass "C: MariaDB installed and initialised by hand (Arch defaults)" || fail "C: manual MariaDB"
sqlc "CREATE DATABASE otherapp; CREATE TABLE otherapp.t (id INT); INSERT INTO otherapp.t VALUES (42)"
inst "$P1" 1 && pass "C: bg10-1 installed" || fail "C: bg10-1 install"
x 'grep -q "ALPM-SCRIPTLET\] betterguac: initialising MariaDB" /var/log/pacman.log' && fail "C: bg10-1 initialised MariaDB anyway" || pass "C: bg10-1 did not initialise the existing MariaDB"
is_open "C before bg10-3" || fail "C: not open before upgrade"
B0=$(data); G0=$(x 'ls /etc/my.cnf.d/; mariadb --protocol=socket -uroot -N -B -e "SELECT User,Host FROM mysql.global_priv ORDER BY 1,2; SHOW DATABASES; SELECT * FROM otherapp.t"' | sha256sum)
M0=$(x 'systemctl show -p MainPID --value mariadb')
inst "$P3" 3 && pass "C: upgrade to bg10-3" || fail "C: upgrade to bg10-3"
is_open "C after bg10-3" && pass "C: MariaDB not set up by BetterGuac still open, as it was" || fail "C: MariaDB was changed"
{ [ "$(x 'ls /etc/my.cnf.d/; mariadb --protocol=socket -uroot -N -B -e "SELECT User,Host FROM mysql.global_priv ORDER BY 1,2; SHOW DATABASES; SELECT * FROM otherapp.t"' | sha256sum)" = "$G0" ] && [ "$(x 'systemctl show -p MainPID --value mariadb')" = "$M0" ] && x '! test -e /etc/my.cnf.d/betterguac-local.cnf && ! test -e /var/lib/betterguac/mariadb-closed-by-package'; } && pass "C: accounts, databases, config folder unchanged, no record file, MariaDB not restarted" || fail "C: something changed"
[ "$(data)" = "$B0" ] && pass "C: BetterGuac data unchanged" || fail "C: data changed"
[ "${KEEP:-0}" = 1 ] || docker rm -f $C >/dev/null

docker rm -f $PEER >/dev/null 2>&1; docker network rm $NET >/dev/null 2>&1; rm -rf "$D"
echo "=== UPGRADE RESULT $TAG pass=$PASS fail=$FAIL ==="
[ "$FAIL" = 0 ]
