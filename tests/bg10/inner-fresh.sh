#!/bin/bash
# Fresh install of the bg10 .deb, the standard checks, RDP/VNC probes and the bg10 checks.
set -u
. /root/common.sh; . /root/bg10-checks.sh
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq /root/new.deb > /root/inst.log 2>&1 && pass "apt install of the bg10 .deb" || { fail "install"; tail -n 15 /root/inst.log; }
G=$(sha256sum /root/new.deb | cut -d' ' -f1); [ "$G" = "$EXPECT_SHA" ] && pass "package checksum matches the build ($G)" || fail "checksum $G"
wait_web || fail "web app did not answer"
bash /root/test-incontainer.sh > /root/std.log 2>&1; grep -E '^(PASS|FAIL|=== RESULT)' /root/std.log
S=$(sed -n 's/=== RESULT pass=\([0-9]*\) fail=\([0-9]*\).*/\1 \2/p' /root/std.log)
set -- $S; PASS=$((PASS+${1:-0})); FAIL=$((FAIL+${2:-1}))
bg10_checks
export PROBE_KEEP=1; probes
for i in $(seq 1 30); do [ "$(sql -e "SELECT COUNT(*) FROM guacamole_connection_history WHERE end_date IS NULL")" = 0 ] && break; sleep 3; done
N=$(sql -e "SELECT COUNT(*) FROM guacamole_connection_history WHERE end_date IS NOT NULL"); [ "$N" -ge 2 ] && pass "web RDP and VNC sessions recorded and ended in session history ($N)" || fail "session history: $N ended rows"
H=$(sql -e "SELECT COUNT(*) FROM guacamole_connection_history WHERE remote_host IS NOT NULL AND remote_host<>''"); echo "history rows with remote_host: $H"
sql -e "SELECT h.connection_name, h.start_date, h.end_date, h.remote_host FROM guacamole_connection_history h ORDER BY history_id"
N=$(systemctl --failed --no-legend | grep -v 'getty@tty' | wc -l); [ "$N" = 0 ] && pass "no failed systemd units (getty on tty1 ignored: containers have no console)" || { fail "$N failed units"; systemctl --failed --no-legend; }
grep -iE "SEVERE" /var/log/tomcat10/catalina.*.log 2>/dev/null | tail -n 5
echo "=== RESULT pass=$PASS fail=$FAIL ==="
