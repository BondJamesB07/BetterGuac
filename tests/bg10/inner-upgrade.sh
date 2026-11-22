#!/bin/bash
# Install bg9, put data in it, upgrade to the bg10 .deb, check data, migrations, backup, sessions.
set -u
. /root/common.sh; . /root/bg10-checks.sh
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq /root/old.deb > /root/old-inst.log 2>&1 && pass "installed old build $(dpkg-query -W -f='${Version}' betterguac)" || { fail "old build install"; tail -5 /root/old-inst.log; }
wait_web || fail "old web app did not answer"
U=$(admin_user); P=$(admin_pw)
OLDSTATE=$(auth_state "$U" "$P"); echo "old build: first admin sign-in: $OLDSTATE"
INSTANCE=$(sed -n 's/^instance: //p' /etc/betterguac/betterguac.yaml)
cat > /root/worked.yaml <<YEOF
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
grep -q '^JANE_PASSWORD=' /etc/betterguac/sync.env || echo "JANE_PASSWORD=Choose-A-Long-Initial-Password" >> /etc/betterguac/sync.env
chmod 600 /etc/betterguac/sync.env
PLAN=$(betterguac-sync plan /root/worked.yaml | sed -n 's/^Plan \([0-9a-f]*\).*/\1/p' | head -1)
betterguac-sync apply /root/worked.yaml --confirm "$PLAN" >/root/apply.log 2>&1 && pass "old build: YAML data applied" || { fail "old build YAML apply"; tail -5 /root/apply.log; }
# a session in the old build's history (RDP to the target)
python3 /root/probe.py web rdp "$TARGET" 3389 probe "$TPW" "$U" "$P" >/dev/null 2>&1 && pass "old build: RDP session through the web app" || fail "old build RDP session"
count(){ echo "$(sql -e "SELECT COUNT(*) FROM guacamole_connection") conns, $(sql -e "SELECT COUNT(*) FROM guacamole_entity WHERE type='USER'") users, $(sql -e "SELECT COUNT(*) FROM guacamole_connection_permission") conn-perms, $(sql -e "SELECT COUNT(*) FROM guacamole_system_permission") sys-perms, $(sql -e "SELECT COUNT(*) FROM guacamole_user_attribute") user-attrs, $(sql -e "SELECT COUNT(*) FROM guacamole_user_group") groups, $(sql -e "SELECT COUNT(*) FROM guacamole_connection_history") history"; }
BEFORE=$(count); echo "before upgrade: $BEFORE"
( cd /etc/betterguac && find . -type f | sort | xargs sha256sum ) > /root/etc-before.sum
apt-get install -y -qq /root/new.deb > /root/new-inst.log 2>&1 && pass "upgrade with apt install of the bg10 .deb" || { fail "upgrade"; tail -n 20 /root/new-inst.log; }
grep -E "backing up|schema|preparing the web|error|warning" -i /root/new-inst.log | head -n 10
sleep 3; wait_web && pass "web app answers after upgrade" || fail "web app after upgrade"
for s in betterguac-guacd tomcat10 mariadb; do systemctl is-active --quiet "$s" && pass "service $s active after upgrade" || fail "service $s after upgrade"; done
NEWSTATE=$(auth_state "$U" "$P")
[ "$NEWSTATE" = "$OLDSTATE" ] && pass "first admin keeps password and two-factor state ($NEWSTATE)" || fail "first admin $OLDSTATE -> $NEWSTATE"
AFTER=$(count); echo "after upgrade:  $AFTER"
[ "$BEFORE" = "$AFTER" ] && pass "connections, users, permissions, attributes, groups and history unchanged" || fail "data changed: '$BEFORE' -> '$AFTER'"
( cd /etc/betterguac && find . -type f | sort | xargs sha256sum ) > /root/etc-after.sum
diff /root/etc-before.sum /root/etc-after.sum > /root/etc.diff && pass "/etc/betterguac regular files unchanged" || { echo "--- /etc/betterguac changes:"; cat /root/etc.diff; fail "/etc/betterguac changed"; }
B=$(ls /var/lib/betterguac/backups/ 2>/dev/null | wc -l); [ "$B" -ge 1 ] && pass "database backup taken before migrations ($(ls /var/lib/betterguac/backups | head -n 1))" || fail "no pre-migration backup"
J=$(auth_state jane@example.com Choose-A-Long-Initial-Password); case $J in TOTP|OK) pass "YAML user jane still accepted ($J)";; *) fail "jane $J";; esac
for l in /etc/betterguac/extensions/*.jar; do [ -e "$l" ] || { fail "dangling extension link $l"; }; done
pass "extension links checked ($(ls /etc/betterguac/extensions | wc -l))"
bg10_checks
probes
TK=$(tok --data-urlencode "username=$U" --data-urlencode "password=$P")
R=$(curl -s "$BASE/api/session/ext/mysql/audit/events?category=session&limit=100" -H "Guacamole-Token: $TK")
echo "$R" | python3 -c 'import sys,json; d=json.load(sys.stdin); it=d.get("items") or d.get("events") or []; print("session events:", len(it)); sys.exit(0 if len(it)>=3 else 1)' && pass "Activity shows the pre-upgrade and new sessions" || fail "Activity session list: $(echo "$R" | head -c 200)"
N=$(systemctl --failed --no-legend | grep -v 'getty@tty' | wc -l); [ "$N" = 0 ] && pass "no failed systemd units (getty on tty1 ignored: containers have no console)" || { fail "$N failed units"; systemctl --failed --no-legend; }
echo "=== RESULT pass=$PASS fail=$FAIL ==="
