#!/bin/bash
# Checks that only a real VM can show. Run as root on the VM after install (and again after reboot).
# usage: vm-checks.sh <label>
set -u
cd /t
source ./common.sh
source ./bg10-checks.sh
L=${1:-vm}
WEB=http://127.0.0.1:8080/betterguac
log(){ echo "--- $*"; }

log "$L: boot and services"
[ "$(cat /proc/1/comm)" = systemd ] && pass "PID 1 is systemd" || fail "PID 1 is $(cat /proc/1/comm)"
[ "$(systemd-detect-virt)" = kvm ] && pass "running in a KVM VM (not a container)" || fail "virt=$(systemd-detect-virt)"
S=$(systemctl is-system-running); { [ "$S" = running ]; } && pass "system state running" || fail "system state $S"
for s in mariadb tomcat10 betterguac-guacd betterguac.target; do
  systemctl is-enabled --quiet $s && systemctl is-active --quiet $s && pass "$s enabled and active" || fail "$s $(systemctl is-enabled $s)/$(systemctl is-active $s)"
done
wait_web && pass "web app 200" || fail "web app not answering"
U=$(admin_user); P=$(admin_pw)
[ "$(auth_state "$U" "$P")" = OK ] && pass "setup admin signs in without a code" || fail "setup admin: $(auth_state "$U" "$P")"
[ "$(auth_state second@example.com "$(cat /root/second.pw 2>/dev/null)")" = TOTP ] && pass "second admin is asked for a code / enrolment" || echo "(second admin not set up yet)"
if systemctl --failed --no-legend | grep -q .; then fail "failed units: $(systemctl --failed --no-legend | awk '{print $2}' | tr '\n' ' ')"; else pass "no failed systemd units"; fi
E=$(journalctl -b --no-pager -q -u betterguac-guacd -u tomcat10 -u mariadb | grep -E 'SEVERE|Exception|\[ERROR\]|guacd\[[0-9]+\]: .*(ERROR|error)' | wc -l)
[ "$E" = 0 ] && pass "no SEVERE/Exception/ERROR lines from guacd, Tomcat or MariaDB this boot" || { fail "$E error lines"; journalctl -b --no-pager -q -u betterguac-guacd -u tomcat10 -u mariadb | grep -E 'SEVERE|Exception|\[ERROR\]|guacd\[[0-9]+\]: .*(ERROR|error)' | tail -5; }

log "$L: systemd behaviour"
PID=$(systemctl show -p MainPID --value betterguac-guacd)
kill -9 "$PID"; sleep 5
N=$(systemctl show -p MainPID --value betterguac-guacd)
{ [ "$N" != 0 ] && [ "$N" != "$PID" ] && systemctl is-active --quiet betterguac-guacd; } && pass "guacd killed with SIGKILL is restarted by systemd (Restart=on-failure)" || fail "guacd after kill: pid=$N $(systemctl is-active betterguac-guacd)"
ss -ltn | grep -q '127.0.0.1:4822' && pass "guacd listening again" || fail "guacd not listening after restart"
systemctl stop betterguac.target; sleep 3
{ ! systemctl is-active --quiet betterguac-guacd && ! systemctl is-active --quiet tomcat10 && systemctl is-active --quiet mariadb; } && pass "stopping betterguac.target stops guacd and Tomcat (PartOf) and leaves MariaDB running" || fail "after stop: guacd=$(systemctl is-active betterguac-guacd) tomcat=$(systemctl is-active tomcat10) mariadb=$(systemctl is-active mariadb)"
systemctl start betterguac.target
wait_web && systemctl is-active --quiet betterguac-guacd && pass "starting betterguac.target brings guacd and the web app back" || fail "start target"
systemctl restart betterguac.target; wait_web && [ "$(auth_state "$U" "$P")" = OK ] && pass "restart betterguac.target: web app back, sign-in works" || fail "restart target"
systemctl restart mariadb; sleep 2; T=$(curl -s --max-time 20 -X POST $WEB/api/tokens --data-urlencode "username=$U" --data-urlencode "password=$P" | grep -c authToken)
[ "$T" = 1 ] && pass "web app reconnects to MariaDB after a database restart" || fail "sign-in after mariadb restart"
systemd-analyze verify /usr/lib/systemd/system/betterguac-guacd.service /usr/lib/systemd/system/betterguac.target >/tmp/verify.txt 2>&1
grep -i betterguac /tmp/verify.txt | grep -q . && fail "systemd-analyze verify: $(grep -i betterguac /tmp/verify.txt | head -2)" || pass "systemd-analyze verify: no complaints about the BetterGuac units"
echo "guacd exposure: $(systemd-analyze security betterguac-guacd 2>/dev/null | tail -1)"

log "$L: network exposure"
ss -ltnH | awk '{print $4}' | sort -u | tr '\n' ' '; echo
ss -ltnH | awk '{print $4}' | grep -qE '(^|[^0-9])127\.0\.0\.1:4822$' && ! ss -ltnH | awk '{print $4}' | grep -qE '(0\.0\.0\.0|\*|\[::\]):4822$' && pass "guacd only on 127.0.0.1" || fail "guacd listen"
if ss -ltnH | awk '{print $4}' | grep -qE '(0\.0\.0\.0|\*|\[::\]):3306$'; then fail "MariaDB listens on all interfaces (3306)"; else pass "MariaDB not listening on the network"; fi
A=$(sql -e "SELECT COUNT(*) FROM mysql.global_priv WHERE user=''" 2>/dev/null)
[ "${A:-1}" = 0 ] && pass "no anonymous MariaDB accounts" || fail "$A anonymous MariaDB accounts"
mariadb --protocol=socket -uroot -N -e "SHOW DATABASES" | grep -qx test && fail "MariaDB 'test' database present" || pass "no MariaDB test database"
setpriv --reuid=nobody --regid=nobody --clear-groups mariadb --protocol=socket -u '' -N -e 'select 1' >/dev/null 2>&1 && fail "an unprivileged local user can sign in to MariaDB anonymously" || pass "unprivileged local user cannot sign in to MariaDB anonymously"
echo "=== VM RESULT $L pass=$PASS fail=$FAIL ==="
