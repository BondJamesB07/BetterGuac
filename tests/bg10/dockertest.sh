#!/bin/bash
# Docker image check: fresh start, SBOM/legal files, migrations, Activity, X-Forwarded-For, RDP/VNC via the web app.
# usage: dockertest.sh <image> <testsdir>
IMG=$1; W=$2; C=bg10-dtest; T=bg10-dtarget; NET=bg10-dnet; P=18093; PASS=0; FAIL=0
pass(){ echo "PASS: $*"; PASS=$((PASS+1)); }; fail(){ echo "FAIL: $*"; FAIL=$((FAIL+1)); }
docker rm -f $C $T >/dev/null 2>&1; docker network create $NET >/dev/null 2>&1
TPW=$(head -c 18 /dev/urandom | base64 | tr -dc A-Za-z0-9 | head -c 16)
docker build -q -t bg10-target -f $W/Dockerfile.target $W >/dev/null
docker run -d --name $T --network $NET -e PW="$TPW" bg10-target >/dev/null
docker run -d --name $C --network $NET -p 127.0.0.1:$P:8080 --health-cmd /usr/local/bin/betterguac-healthcheck --health-interval 15s --health-timeout 5s --health-retries 5 --health-start-period 90s $IMG >/dev/null
echo "image $(docker inspect -f '{{.Architecture}} {{index .Config.Labels "org.opencontainers.image.version"}} rev={{index .Config.Labels "org.opencontainers.image.revision"}}' $IMG)"
for i in $(seq 1 90); do [ "$(docker inspect -f '{{.State.Health.Status}}' $C)" = healthy ] && break; sleep 3; done
[ "$(docker inspect -f '{{.State.Health.Status}}' $C)" = healthy ] && pass "container healthy" || { fail "not healthy"; docker logs $C | tail -n 30; }
B=http://127.0.0.1:$P/betterguac
[ "$(curl -s -o /dev/null -w '%{http_code}' $B/)" = 200 ] && pass "web app 200" || fail "web app"
U=$(docker exec $C sed -n 's/^username: //p' /etc/betterguac/initial-admin.txt); PW=$(docker exec $C sed -n 's/^password: //p' /etc/betterguac/initial-admin.txt)
sql(){ docker exec -i $C mariadb --protocol=socket -uroot -N -B betterguac "$@"; }
docker exec $C test -f /var/cache/betterguac/webapp/WEB-INF/web.xml && pass "web app converted at container start" || fail "no converted webapp"
N=$(docker exec $C sh -c 'tail -n +2 /usr/share/betterguac/legal/sbom/packages.tsv | wc -l'); [ "$N" -gt 250 ] && pass "SBOM lists $N packages" || fail "SBOM $N"
docker exec $C python3 -c 'import json; d=json.load(open("/usr/share/betterguac/legal/sbom/betterguac.spdx.json")); assert d["spdxVersion"]=="SPDX-2.3" and len(d["packages"])>250; print(len(d["packages"]))' >/dev/null && pass "SPDX 2.3 document valid JSON" || fail "SPDX"
docker exec $C grep -qE "^mariadb-server	" /usr/share/betterguac/legal/sbom/packages.tsv && docker exec $C grep -qE "^libvncclient1	" /usr/share/betterguac/legal/sbom/packages.tsv && pass "SBOM includes mariadb-server and libvncclient1" || fail "SBOM content"
docker exec $C grep -q "deb.debian.org/debian/pool/main" /usr/share/betterguac/legal/SOURCES && pass "SOURCES points to the Debian archive" || fail "SOURCES"
docker exec $C test -s /usr/share/doc/mariadb-server/copyright && pass "package copyright files kept in the image" || fail "copyright files missing"
[ "$(sql -e 'SELECT COUNT(*) FROM bg_schema_migration')" -ge 1 ] && pass "migrations applied on fresh start" || fail "migrations"
curl -s -o /dev/null -X POST $B/api/tokens -H 'X-Forwarded-For: 198.51.100.23' --data-urlencode username=xff@example.com --data-urlencode password=x
sleep 1; A=$(sql -e "SELECT remote_addr FROM bg_audit_event WHERE actor='xff@example.com' ORDER BY event_id DESC LIMIT 1")
[ "$A" = 198.51.100.23 ] && pass "X-Forwarded-For from the Docker gateway (private) recorded as the client ($A)" || fail "XFF got $A"
docker cp $W/probe.py $C:/tmp/probe.py >/dev/null
for proto in rdp vnc; do port=3389; [ $proto = vnc ] && port=5901
  docker exec $C python3 /tmp/probe.py web $proto $T $port probe "$TPW" "$U" "$PW" > /tmp/dprobe.log 2>&1 && pass "web app $proto session streamed the desktop" || { fail "web $proto"; tail -n 5 /tmp/dprobe.log; }
done
TK=$(curl -s -X POST $B/api/tokens --data-urlencode "username=$U" --data-urlencode "password=$PW" | python3 -c 'import sys,json;print(json.load(sys.stdin)["authToken"])')
[ "$(curl -s -o /dev/null -w '%{http_code}' "$B/api/session/ext/mysql/audit/events?limit=10" -H "Guacamole-Token: $TK")" = 200 ] && pass "Activity API 200" || fail "Activity API"
docker restart $C >/dev/null; for i in $(seq 1 60); do [ "$(docker inspect -f '{{.State.Health.Status}}' $C)" = healthy ] && break; sleep 3; done
[ "$(docker inspect -f '{{.State.Health.Status}}' $C)" = healthy ] && pass "healthy again after restart" || fail "restart"
docker logs $C 2>&1 | grep -iE "preparing the web" | head -n 3
docker rm -f $C $T >/dev/null; docker network rm $NET >/dev/null; echo "=== RESULT pass=$PASS fail=$FAIL ==="
