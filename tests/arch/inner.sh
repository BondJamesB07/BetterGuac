#!/bin/bash
# Inside a fresh Arch systemd container. Env: PKG, TARGET, TPW, SSHT, MJC_SHA
set -u
cd /t
source ./common.sh
source ./bg10-checks.sh
WEB=http://127.0.0.1:8080/betterguac
log(){ echo "--- $*"; }

log "fresh install: pacman -U $(basename $PKG)"
T0=$(date +%s)
pacman -Sy >/dev/null 2>&1
pacman -U --noconfirm "$PKG" > /root/install.log 2>&1; rc=$?
grep -iE 'error|warning|betterguac:|installing betterguac' /root/install.log | grep -v '^password' | tail -20
[ $rc = 0 ] && pass "pacman -U installs with its dependencies ($(( $(date +%s)-T0 ))s)" || { fail "pacman -U rc=$rc"; tail -40 /root/install.log; }
wait_web && pass "web app answers 200 at /betterguac/" || fail "web app not answering"
for s in mariadb tomcat10 betterguac-guacd betterguac.target; do
  systemctl is-enabled --quiet $s && pass "$s enabled" || fail "$s not enabled"
done
C=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/); { [ "$C" = 302 ] || [ "$C" = 200 ]; } && pass "root URL answers ($C)" || fail "root URL $C"
ss -ltn | grep -q '127.0.0.1:4822' && pass "guacd listens on 127.0.0.1:4822" || fail "guacd listen: $(ss -ltn | grep 4822)"
[ "$(stat -c '%U:%G %a' /etc/betterguac/initial-admin.txt)" = "root:root 600" ] && pass "initial-admin.txt root:root 600" || fail "initial-admin.txt $(stat -c '%U:%G %a' /etc/betterguac/initial-admin.txt)"
[ "$(stat -c '%G' /etc/betterguac/keys)" = tomcat10 ] && pass "keys folder group tomcat10" || fail "keys folder $(stat -c '%U:%G %a' /etc/betterguac/keys)"

log "core checks (shared with the .deb tests)"
bash ./test-incontainer.sh > /root/core.log 2>&1
grep -E '^(PASS|FAIL)' /root/core.log
P1=$(grep -c '^PASS' /root/core.log); F1=$(grep -c '^FAIL' /root/core.log); PASS=$((PASS+P1)); FAIL=$((FAIL+F1))

log "bg10 checks (shared with the .deb tests)"
bg10_checks
for f in legal/mariadb-connector-j/LICENSE legal/jakartaee-migration/LICENSE.txt legal/jakartaee-migration/NOTICE.txt; do [ -s /usr/share/betterguac/$f ] && pass "$f present" || fail "$f missing"; done
grep -q 'MariaDB Connector/J 2.7.15' /usr/share/betterguac/legal/SOURCES && grep -q 'jakartaee-migration/v1.0.13/source' /usr/share/betterguac/legal/SOURCES && pass "SOURCES lists the two bundled Java components with source pointers" || fail "SOURCES Arch section"
[ -s /usr/share/licenses/betterguac/LICENSE ] && pass "/usr/share/licenses/betterguac/LICENSE present" || fail "license dir"
sha256sum /usr/share/betterguac/java/mariadb-java-client-2.7.15.jar | grep -q "^$MJC_SHA " && pass "Connector/J jar is the stock Maven Central jar" || fail "Connector/J jar checksum"

log "SSH session with a key given by file path (YAML sync)"
install -m 640 -g tomcat10 /t/ssh/id_ed25519 /etc/betterguac/keys/test_ssh_key
setpriv --reuid=tomcat10 --regid=tomcat10 --init-groups test -r /etc/betterguac/keys/test_ssh_key && pass "tomcat10 can read the SSH key" || fail "tomcat10 cannot read key"
INSTANCE=$(sed -n 's/^instance: //p' /etc/betterguac/betterguac.yaml)
U=$(admin_user); P=$(admin_pw)
cat > /root/ssh.yaml <<EOF
version: 1
kind: guacamole-db-sync
instance: $INSTANCE
connections:
  - key: web-01
    name: Web-01
    protocol: ssh
    params:
      hostname: 192.0.2.10
      port: 22
      username: admin
  - key: ssh-target
    name: SSH-Target
    protocol: ssh
    params:
      hostname: $SSHT
      port: 22
      username: tester
      private-key-file: /etc/betterguac/keys/test_ssh_key
users:
  - username: jane@example.com
    email: jane@example.com
    password: {env: JANE_PASSWORD}
    password_mode: initial
    connections: [web-01]
EOF
betterguac-sync check /root/ssh.yaml >/root/sync.log 2>&1 && pass "YAML check with private-key-file" || { fail "YAML check"; cat /root/sync.log; }
PLAN=$(betterguac-sync plan /root/ssh.yaml | sed -n 's/^Plan \([0-9a-f]*\).*/\1/p' | head -1)
[ -n "$PLAN" ] && betterguac-sync apply /root/ssh.yaml --confirm "$PLAN" >>/root/sync.log 2>&1 && pass "YAML plan/apply created the SSH connection" || { fail "YAML plan/apply"; tail -20 /root/sync.log; }
CID=$(sql -e "SELECT connection_id FROM guacamole_connection WHERE connection_name='SSH-Target'")
GID=$(sql -e "SELECT entity_id FROM guacamole_entity WHERE name='$U'")
sql -e "INSERT IGNORE INTO guacamole_connection_permission (entity_id,connection_id,permission) VALUES ($GID,$CID,'READ')"
python3 ./probe.py conn "$CID" "$U" "$P" > /root/sshprobe.log 2>&1 && pass "SSH session through the web app (key by file path) drew the terminal" || { fail "SSH session"; tail -8 /root/sshprobe.log; }
grep -E 'web-tunnel|opening' /root/sshprobe.log
sleep 2
N=$(sql -e "SELECT COUNT(*) FROM guacamole_connection_history WHERE connection_name='SSH-Target'")
[ "${N:-0}" -ge 1 ] && pass "SSH session in session history ($N)" || fail "no SSH history"
TK=$(tok --data-urlencode "username=$U" --data-urlencode "password=$P")
N=$(curl -s "$WEB/api/session/ext/mysql/audit/events?limit=200&category=session" -H "Guacamole-Token: $TK" | grep -o '"session\.\(start\|end\)"' | wc -l)
[ "${N:-0}" -ge 1 ] && pass "Activity page API lists the SSH session ($N start/end rows)" || fail "no session rows in Activity API"
C=$(curl -s "$WEB/api/session/ext/mysql/audit/export" -H "Guacamole-Token: $(tok --data-urlencode "username=$U" --data-urlencode "password=$P")" | head -c 2000)
echo "$C" | head -1 | grep -q ',' && echo "$C" | grep -q 'auth' && pass "CSV export has a header and rows" || fail "CSV content: $(echo "$C" | head -2)"

log "RDP and VNC"
probes > /root/probes.log 2>&1
grep -E '^(PASS|FAIL)|web-tunnel|guacd-direct' /root/probes.log

log "reinstall over itself"
A0=$(sql -e "SELECT COUNT(*) FROM guacamole_user"); C0=$(sql -e "SELECT COUNT(*) FROM guacamole_connection"); H0=$(sql -e "SELECT COUNT(*) FROM guacamole_connection_history")
S0=$(sha256sum /etc/betterguac/guacamole.properties /etc/betterguac/sync.env /etc/betterguac/betterguac.yaml /etc/betterguac/initial-admin.txt | sha256sum)
pacman -U --noconfirm "$PKG" > /root/reinstall.log 2>&1 && pass "pacman -U over itself" || { fail "reinstall"; tail -20 /root/reinstall.log; }
wait_web && pass "web app back after reinstall" || fail "web app down after reinstall"
A1=$(sql -e "SELECT COUNT(*) FROM guacamole_user"); C1=$(sql -e "SELECT COUNT(*) FROM guacamole_connection"); H1=$(sql -e "SELECT COUNT(*) FROM guacamole_connection_history")
[ "$A0/$C0/$H0" = "$A1/$C1/$H1" ] && pass "users/connections/history unchanged ($A1/$C1/$H1)" || fail "counts $A0/$C0/$H0 -> $A1/$C1/$H1"
S1=$(sha256sum /etc/betterguac/guacamole.properties /etc/betterguac/sync.env /etc/betterguac/betterguac.yaml /etc/betterguac/initial-admin.txt | sha256sum)
[ "$S0" = "$S1" ] && pass "settings files byte-identical after reinstall" || fail "settings changed by reinstall"
[ "$(login_code "$U" "$P")" = 200 ] && pass "setup admin still signs in" || fail "sign-in after reinstall"
betterguac-admin migrate --status | grep -q . && pass "migrate --status after reinstall" || fail "migrate status after reinstall"
for s in betterguac-guacd tomcat10 mariadb; do systemctl is-active --quiet $s && pass "$s active after reinstall" || fail "$s inactive after reinstall"; done

log "removal"
pacman -R --noconfirm betterguac > /root/remove.log 2>&1 && pass "pacman -R betterguac" || { fail "pacman -R"; tail -20 /root/remove.log; }
grep 'betterguac:' /root/remove.log
for i in $(seq 60); do C=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 $WEB/); [ "$C" != 000 ] && break; sleep 2; done
[ "$C" = 404 ] && pass "web app undeployed (404)" || fail "web app after removal: $C"
systemctl is-active --quiet betterguac-guacd && fail "guacd still running" || pass "guacd stopped"
{ [ ! -e /usr/lib/systemd/system/betterguac-guacd.service ] && [ ! -e /usr/lib/betterguac ] && [ ! -e /var/cache/betterguac ]; } && pass "program files and converted web app removed" || fail "leftovers: $(ls -d /usr/lib/betterguac /var/cache/betterguac 2>/dev/null)"
{ [ -s /etc/betterguac/guacamole.properties ] && [ -s /etc/betterguac/keys/test_ssh_key ]; } && pass "/etc/betterguac kept" || fail "/etc/betterguac not kept"
[ "$(sql -e 'SELECT COUNT(*) FROM guacamole_user')" = "$A1" ] && pass "databases kept" || fail "database not kept"
ls /etc/tomcat10/Catalina/localhost/ 2>/dev/null | grep -qi 'betterguac\|guacamole' && fail "Tomcat context left behind" || pass "no Tomcat context left"

log "install again after removal (keeps the old data)"
{ pacman -U --noconfirm "$PKG" > /root/reinstall2.log 2>&1 && wait_web && [ "$(login_code "$U" "$P")" = 200 ] && [ "$(sql -e 'SELECT COUNT(*) FROM guacamole_user')" = "$A1" ]; } && pass "reinstall after removal: same data, setup admin signs in" || { fail "reinstall after removal"; tail -20 /root/reinstall2.log; }

if systemctl --failed --no-legend | grep -q .; then fail "failed units: $(systemctl --failed --no-legend | awk '{print $2}' | tr '\n' ' ')"; else pass "no failed systemd units"; fi
echo "=== ARCH RESULT pass=$PASS fail=$FAIL ==="
[ "$FAIL" = 0 ]
