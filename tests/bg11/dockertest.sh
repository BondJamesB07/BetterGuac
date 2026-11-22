#!/bin/bash
# bg11 Docker image checks.
#   fresh:   new image on empty volumes; versions of the refreshed parts, SSH/RDP/VNC
#            through the web app, two-factor prompt, Activity, migrations, restart.
#   upgrade: the bg10 image on named volumes with data (YAML users/connections,
#            an RDP session in history, a TOTP-enrolled user), then the bg11 image
#            on the same volumes: data, files and two-factor state unchanged.
# usage: dockertest.sh <fresh|upgrade> <new image> <tests/bg10 dir> [old image]
set -u
MODE=$1; IMG=$2; W=$3; OLD=${4:-}
A=$(docker inspect -f '{{.Architecture}}' "$IMG")
C=bg11-d$MODE-$A; T=bg11-dtarget-$A; S=bg11-dssh-$A; NET=bg11-dnet-$A; P=$((18100 + RANDOM % 800))
V=bg11test-$MODE-$A
PASS=0; FAIL=0
pass(){ echo "PASS: $*"; PASS=$((PASS+1)); }; fail(){ echo "FAIL: $*"; FAIL=$((FAIL+1)); }
sql(){ docker exec -i $C mariadb --protocol=socket -uroot -N -B betterguac "$@"; }
B=http://127.0.0.1:$P/betterguac
cleanup(){ docker rm -f $C $T $S >/dev/null 2>&1; docker network rm $NET >/dev/null 2>&1; for v in db conf state logs; do docker volume rm -f $V-$v >/dev/null 2>&1; done; }
cleanup
docker network create $NET >/dev/null
TPW=$(head -c 18 /dev/urandom | base64 | tr -dc A-Za-z0-9 | head -c 16)
docker build -q -t bg10-target -f $W/Dockerfile.target $W >/dev/null
docker run -d --name $T --network $NET -e PW="$TPW" bg10-target >/dev/null
# SSH target: a small Debian sshd
docker run -d --name $S --network $NET debian:trixie-slim sh -c "apt-get update -qq >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server >/dev/null && useradd -m tester && echo tester:$TPW | chpasswd && mkdir -p /run/sshd && echo READY && exec /usr/sbin/sshd -D -e -o PasswordAuthentication=yes" >/dev/null
run(){ docker run -d --name $C --network $NET -p 127.0.0.1:$P:8080 \
  -v $V-db:/var/lib/mysql -v $V-conf:/etc/betterguac -v $V-state:/var/lib/betterguac -v $V-logs:/var/log/betterguac \
  --health-cmd /usr/local/bin/betterguac-healthcheck --health-interval 10s --health-timeout 5s --health-retries 5 --health-start-period 120s "$1" >/dev/null; }
healthy(){ for i in $(seq 1 100); do [ "$(docker inspect -f '{{.State.Health.Status}}' $C 2>/dev/null)" = healthy ] && return 0; sleep 3; done; return 1; }
tok(){ curl -s --max-time 20 -X POST $B/api/tokens --data-urlencode "username=$1" --data-urlencode "password=$2" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("authToken",""))' 2>/dev/null; }
authstate(){ local r; r=$(curl -s --max-time 20 -X POST $B/api/tokens --data-urlencode "username=$1" --data-urlencode "password=$2"); case "$r" in *authToken*) echo OK;; *guac-totp*|*TOTP*|*totp*) echo TOTP;; *) echo DENIED;; esac; }
totp(){ python3 -c 'import base64,hmac,hashlib,struct,time; k=base64.b32decode("JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP"); h=hmac.new(k,struct.pack(">Q",int(time.time())//30),hashlib.sha1).digest(); o=h[-1]&15; print("%06d"%((struct.unpack(">I",h[o:o+4])[0]&0x7fffffff)%1000000))'; }
totptok(){ curl -s --max-time 20 -X POST $B/api/tokens --data-urlencode "username=$1" --data-urlencode "password=$2" --data-urlencode "guac-totp=$(totp)" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("authToken",""))' 2>/dev/null; }
count(){ echo "$(sql -e 'SELECT COUNT(*) FROM guacamole_connection') conns, $(sql -e "SELECT COUNT(*) FROM guacamole_entity WHERE type='USER'") users, $(sql -e 'SELECT COUNT(*) FROM guacamole_connection_permission') conn-perms, $(sql -e 'SELECT COUNT(*) FROM guacamole_system_permission') sys-perms, $(sql -e 'SELECT COUNT(*) FROM guacamole_user_attribute') user-attrs, $(sql -e 'SELECT COUNT(*) FROM guacamole_connection_history') history"; }
for i in $(seq 1 120); do docker logs $S 2>&1 | grep -q READY && break; sleep 2; done
docker cp $W/probe.py $C:/tmp/probe.py >/dev/null 2>&1 || true

if [ "$MODE" = upgrade ]; then
  echo "old image: $(docker inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' $OLD)"
  run "$OLD"; healthy && pass "bg10 image healthy on new volumes" || { fail "bg10 not healthy"; docker logs $C | tail -20; }
  docker cp $W/probe.py $C:/tmp/probe.py >/dev/null
  U=$(docker exec $C sed -n 's/^username: //p' /etc/betterguac/initial-admin.txt); PW=$(docker exec $C sed -n 's/^password: //p' /etc/betterguac/initial-admin.txt)
  INST=$(docker exec $C sed -n 's/^instance: //p' /etc/betterguac/betterguac.yaml)
  docker exec -i $C sh -c 'cat > /etc/betterguac/worked.yaml' <<YEOF
version: 1
kind: guacamole-db-sync
instance: $INST
connections:
  - key: web-01
    name: Web-01
    protocol: ssh
    params:
      hostname: 192.0.2.10
      port: 22
      username: admin
  - key: desk-01
    name: Desk-01
    protocol: rdp
    params:
      hostname: 192.0.2.20
      port: 3389
users:
  - username: jane@example.com
    email: jane@example.com
    password: {env: JANE_PASSWORD}
    password_mode: initial
    connections: [web-01, desk-01]
YEOF
  docker exec $C sh -c 'grep -q "^JANE_PASSWORD=" /etc/betterguac/sync.env || echo "JANE_PASSWORD=Choose-A-Long-Initial-Password" >> /etc/betterguac/sync.env'
  PLAN=$(docker exec $C betterguac-sync plan /etc/betterguac/worked.yaml | sed -n 's/^Plan \([0-9a-f]*\).*/\1/p' | head -1)
  docker exec $C betterguac-sync apply /etc/betterguac/worked.yaml --confirm "$PLAN" >/dev/null 2>&1 && pass "bg10: YAML data applied" || fail "bg10: YAML apply"
  docker exec $C python3 /tmp/probe.py web rdp $T 3389 probe "$TPW" "$U" "$PW" >/dev/null 2>&1 && pass "bg10: RDP session through the web app" || fail "bg10: RDP session"
  # jane is enrolled in two-factor on bg10: a confirmed TOTP key, stored as the
  # TOTP extension stores it (user attributes)
  sql -e "INSERT INTO guacamole_user_attribute (user_id,attribute_name,attribute_value) SELECT u.user_id,'guac-totp-key-secret','JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP' FROM guacamole_user u JOIN guacamole_entity e USING(entity_id) WHERE e.name='jane@example.com'; INSERT INTO guacamole_user_attribute (user_id,attribute_name,attribute_value) SELECT u.user_id,'guac-totp-key-confirmed','true' FROM guacamole_user u JOIN guacamole_entity e USING(entity_id) WHERE e.name='jane@example.com'"
  JS=$(authstate jane@example.com Choose-A-Long-Initial-Password); [ "$JS" = TOTP ] && pass "bg10: enrolled user is asked for a two-factor code" || fail "bg10 jane: $JS"
  [ -n "$(totptok jane@example.com Choose-A-Long-Initial-Password)" ] && pass "bg10: enrolled user signs in with a TOTP code" || fail "bg10: TOTP sign-in"
  sleep 5
  BEFORE=$(count); echo "before upgrade: $BEFORE"
  docker exec $C sh -c 'cd /etc/betterguac && find . -type f ! -name "*.log" | sort | xargs sha256sum' > /tmp/$V-etc-before.sum
  OWN_B=$(docker exec $C sh -c 'stat -c "%u:%g %n" /var/lib/mysql /var/lib/mysql/betterguac /etc/betterguac /etc/betterguac/guacamole.properties /var/lib/betterguac' )
  docker stop -t 120 $C >/dev/null; docker rm $C >/dev/null
  run "$IMG"; healthy && pass "bg11 image healthy on the bg10 volumes" || { fail "bg11 not healthy on bg10 volumes"; docker logs $C | tail -40; }
  docker cp $W/probe.py $C:/tmp/probe.py >/dev/null
  OWN_A=$(docker exec $C sh -c 'stat -c "%u:%g %n" /var/lib/mysql /var/lib/mysql/betterguac /etc/betterguac /etc/betterguac/guacamole.properties /var/lib/betterguac')
  [ "$OWN_A" = "$OWN_B" ] && pass "volume ownership unchanged ($(echo $OWN_A | tr '\n' ' '))" || fail "ownership: '$OWN_B' -> '$OWN_A'"
  AFTER=$(count); echo "after upgrade:  $AFTER"
  [ "$BEFORE" = "$AFTER" ] && pass "connections, users, permissions, attributes and history unchanged" || fail "data changed: '$BEFORE' -> '$AFTER'"
  docker exec $C sh -c 'cd /etc/betterguac && find . -type f ! -name "*.log" | sort | xargs sha256sum' > /tmp/$V-etc-after.sum
  diff /tmp/$V-etc-before.sum /tmp/$V-etc-after.sum && pass "/etc/betterguac regular files unchanged" || fail "/etc/betterguac files changed"
  L=$(docker exec $C readlink -f /etc/betterguac/lib/mariadb-java-client.jar); case "$L" in */mariadb-java-client-2.7.15.jar) pass "JDBC link in the settings volume moved to Connector/J 2.7.15";; *) fail "JDBC link -> $L";; esac
  J2=$(authstate jane@example.com Choose-A-Long-Initial-Password); [ "$J2" = TOTP ] && pass "after upgrade: enrolled user is still asked for a two-factor code" || fail "jane after upgrade: $J2"
  sleep 31; [ -n "$(totptok jane@example.com Choose-A-Long-Initial-Password)" ] && pass "after upgrade: enrolled user signs in with a TOTP code from the same key" || fail "TOTP sign-in after upgrade"
  [ "$(authstate "$U" "$PW")" = OK ] && pass "first admin signs in after upgrade" || fail "first admin sign-in after upgrade"
  N=$(sql -e 'SELECT COUNT(*) FROM bg_schema_migration'); [ "${N:-0}" -ge 1 ] && pass "schema migrations recorded after upgrade ($N)" || fail "migrations after upgrade"
  docker exec $C betterguac-admin migrate --status 2>&1 | tail -n 4
else
  run "$IMG"; healthy && pass "container healthy on empty volumes" || { fail "not healthy"; docker logs $C | tail -40; }
  docker cp $W/probe.py $C:/tmp/probe.py >/dev/null
  U=$(docker exec $C sed -n 's/^username: //p' /etc/betterguac/initial-admin.txt); PW=$(docker exec $C sed -n 's/^password: //p' /etc/betterguac/initial-admin.txt)
  [ "$(sql -e 'SELECT COUNT(*) FROM bg_schema_migration')" -ge 1 ] && pass "migrations applied on first start" || fail "migrations"
  docker exec -i $C python3 - <<'PY' && pass "second admin is asked to enroll two-factor" || fail "two-factor prompt"
import hashlib,secrets,subprocess,json,urllib.request,urllib.parse
pw='Second-Admin-Pass-123'; user='second@example.com'
salt=secrets.token_bytes(32); h=hashlib.sha256((pw+salt.hex().upper()).encode()).hexdigest()
subprocess.run(['mariadb','--protocol=socket','-uroot','betterguac'],input=f"""INSERT INTO guacamole_entity (name,type) VALUES ('{user}','USER');
SET @e=LAST_INSERT_ID();
INSERT INTO guacamole_user (entity_id,password_hash,password_salt,password_date,email_address) VALUES (@e,UNHEX('{h}'),UNHEX('{salt.hex()}'),NOW(),'{user}');
INSERT INTO guacamole_system_permission (entity_id,permission) VALUES (@e,'ADMINISTER');""",text=True,check=True)
req=urllib.request.Request('http://127.0.0.1:8080/betterguac/api/tokens',data=urllib.parse.urlencode({'username':user,'password':pw}).encode())
try: body=urllib.request.urlopen(req).read().decode()
except urllib.error.HTTPError as e: body=e.read().decode()
assert 'totp' in body.lower() or 'TOTP' in body, body[:300]
PY
fi

# both modes: the running bg11 image
V11=$(docker exec $C dpkg-query -W -f='${Version}' betterguac); [ "$V11" = 1.6.0+bg11 ] && pass "package in the image is $V11" || fail "package $V11"
TV=$(docker exec $C java -cp /usr/share/betterguac/tomcat/lib/catalina.jar org.apache.catalina.util.ServerInfo | sed -n 's/^Server number: *//p'); [ "$TV" = 10.1.62.0 ] && pass "Tomcat $TV" || fail "Tomcat $TV"
docker exec $C sh -c 'ps -eo user,args | grep -v grep | grep catalina.home=/usr/share/betterguac/tomcat | grep -q ^tomcat' && pass "Tomcat runs as tomcat from the bundled Tomcat" || fail "Tomcat process"
docker exec $C sh -c '! dpkg -l tomcat10 libtomcat10-java tomcat-jakartaee-migration libmariadb-java libcommons-lang3-java 2>/dev/null | grep -q ^ii' && pass "no tomcat10, migration, libmariadb-java or commons-lang3 packages in the image" || fail "old packages present"
FR=$(docker exec $C dpkg-query -W -f='${Version}' libfreerdp3-3); case "$FR" in 3.33.1*) pass "FreeRDP $FR";; *) fail "FreeRDP $FR";; esac
ID=$(docker exec $C sh -c 'echo $(id -u tomcat):$(id -g tomcat) $(id -u mysql):$(id -g mysql)'); [ "$ID" = "997:997 100:101" ] && pass "user IDs tomcat 997:997, mysql 100:101" || fail "IDs $ID"
docker exec $C test -f /var/cache/betterguac/webapp/WEB-INF/lib/jackson-databind-2.21.8.jar && docker exec $C test -f /var/cache/betterguac/webapp/WEB-INF/lib/guava-33.8.0-jre.jar && docker exec $C test -f /var/cache/betterguac/webapp/WEB-INF/lib/logback-classic-1.5.38.jar && pass "web app runs Jackson 2.21.8, Guava 33.8.0, Logback 1.5.38" || fail "refreshed jars"
[ "$(curl -s -o /dev/null -w '%{http_code}' $B/)" = 200 ] && pass "web app 200" || fail "web app"
curl -s -o /dev/null -X POST $B/api/tokens --data-urlencode username=failtest@example.com --data-urlencode password=wrong
sleep 1; XA=$(sql -e "SELECT action FROM bg_audit_event WHERE actor='failtest@example.com' ORDER BY event_id DESC LIMIT 1")
[ "$XA" = auth.failed ] && pass "Activity log records a failed sign-in ($XA)" || fail "failed sign-in event: '$XA'"
TK=$(tok "$U" "$PW")
[ "$(curl -s -o /dev/null -w '%{http_code}' "$B/api/session/ext/mysql/audit/events?limit=10" -H "Guacamole-Token: $TK")" = 200 ] && pass "Activity API 200" || fail "Activity API"
for proto in rdp vnc; do port=3389; [ $proto = vnc ] && port=5901
  docker exec $C python3 /tmp/probe.py web $proto $T $port probe "$TPW" "$U" "$PW" > /tmp/$V-probe.log 2>&1 && pass "web app $proto session streamed the desktop" || { fail "web $proto"; tail -n 5 /tmp/$V-probe.log; }
done
docker exec $C python3 /tmp/probe.py web ssh $S 22 tester "$TPW" "$U" "$PW" > /tmp/$V-probe.log 2>&1 && pass "web app ssh session streamed the terminal" || { fail "web ssh"; tail -n 5 /tmp/$V-probe.log; }
docker logs $C 2>&1 | grep -E "SEVERE|Exception" | grep -v -i "failtest@example\|invalid login" | head -n 5
docker restart $C >/dev/null; healthy && pass "healthy again after restart" || fail "restart"
TK=$(tok "$U" "$PW"); [ -n "$TK" ] && pass "admin signs in after restart" || fail "sign-in after restart"
cleanup; rm -f /tmp/$V-*
echo "=== RESULT $MODE $A pass=$PASS fail=$FAIL ==="
