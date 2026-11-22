#!/bin/bash
# Inside a fresh systemd container after install. PASS/FAIL per brief check.
set -u
PASS=0; FAIL=0
pass(){ echo "PASS: $*"; PASS=$((PASS+1)); }
fail(){ echo "FAIL: $*"; FAIL=$((FAIL+1)); }
sql(){ mariadb --protocol=socket -uroot -N -B betterguac "$@"; }

sleep 5
for s in betterguac-guacd tomcat10 mariadb; do
    systemctl is-active --quiet "$s" && pass "service $s active" || fail "service $s not active"
done

PW=$(sed -n 's/^password: //p' /etc/betterguac/initial-admin.txt)
USER=$(sed -n 's/^username: //p' /etc/betterguac/initial-admin.txt)
echo "setup user=$USER pwlen=${#PW}"
B=$(curl -s -w '\n%{http_code}' --max-time 20 -X POST http://127.0.0.1:8080/betterguac/api/tokens --data-urlencode "username=$USER" --data-urlencode "password=$PW")
CODE=$(echo "$B" | tail -1); BODY=$(echo "$B" | sed '$d')
echo "setup login: $CODE $(echo "$BODY" | head -c 300)"
[ "$CODE" = 200 ] && pass "setup admin signs in, no TOTP" || fail "setup admin login HTTP $CODE"
ATTR=$(sql -e "SELECT a.attribute_value FROM guacamole_user_attribute a JOIN guacamole_user u ON u.user_id=a.user_id JOIN guacamole_entity e ON e.entity_id=u.entity_id WHERE e.name='$USER' AND a.attribute_name='guac-totp-disabled'")
[ "$ATTR" = true ] && pass "setup admin guac-totp-disabled=true" || fail "setup admin attribute '$ATTR'"

PW2=$(python3 -c 'import secrets; print(secrets.token_urlsafe(12))')
python3 - "$PW2" <<'PY'
import hashlib,secrets,subprocess,sys
pw=sys.argv[1]; user='second@example.com'
salt=secrets.token_bytes(32); h=hashlib.sha256((pw+salt.hex().upper()).encode()).hexdigest()
subprocess.run(['mariadb','--protocol=socket','-uroot','betterguac'],input=f"""INSERT INTO guacamole_entity (name,type) VALUES ('{user}','USER');
SET @e=LAST_INSERT_ID();
INSERT INTO guacamole_user (entity_id,password_hash,password_salt,password_date,email_address,full_name) VALUES (@e,UNHEX('{h}'),UNHEX('{salt.hex()}'),NOW(),'{user}','Second');
SET @u=LAST_INSERT_ID();
INSERT INTO guacamole_system_permission (entity_id,permission) VALUES (@e,'ADMINISTER');
""",text=True,check=True)
PY
B2=$(curl -s -w '\n%{http_code}' --max-time 20 -X POST http://127.0.0.1:8080/betterguac/api/tokens --data-urlencode "username=second@example.com" --data-urlencode "password=$PW2")
C2=$(echo "$B2" | tail -1); B2BODY=$(echo "$B2" | sed '$d')
echo "second login: $C2 $(echo "$B2BODY" | head -c 300)"
echo "$B2BODY" | grep -qi 'TOTP\|AuthenticationCode\|FORM\|enroll' && pass "second admin asked to enroll TOTP" || fail "second admin TOTP prompt HTTP $C2"

cp /etc/betterguac/betterguac.yaml /root/starter.yaml
betterguac-sync check /root/starter.yaml && pass "untouched starter check" || fail "untouched starter check"
INSTANCE=$(sed -n 's/^instance: //p' /etc/betterguac/betterguac.yaml)
cat > /root/worked.yaml <<EOF
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
users:
  - username: jane@example.com
    email: jane@example.com
    password: {env: JANE_PASSWORD}
    password_mode: initial
    connections: [web-01]
EOF
grep -q '^JANE_PASSWORD=' /etc/betterguac/sync.env || echo "JANE_PASSWORD=Choose-A-Long-Initial-Password" >> /etc/betterguac/sync.env
chmod 600 /etc/betterguac/sync.env
betterguac-sync check /root/worked.yaml && pass "worked example check" || fail "worked example check"
PLAN=$(betterguac-sync plan /root/worked.yaml | sed -n 's/^Plan \([0-9a-f]*\).*/\1/p' | head -1)
[ -n "$PLAN" ] && pass "worked example plan" || fail "worked example plan"
if [ -n "$PLAN" ]; then
    betterguac-sync apply /root/worked.yaml --confirm "$PLAN" && pass "worked example apply" || fail "worked example apply"
    NCON=$(sql -e "SELECT COUNT(*) FROM guacamole_connection WHERE connection_name='Web-01'")
    NUSR=$(sql -e "SELECT COUNT(*) FROM guacamole_entity WHERE name='jane@example.com' AND type='USER'")
    [ "$NCON" = 1 ] && [ "$NUSR" = 1 ] && pass "apply created 1 connection and 1 user" || fail "apply counts conn=$NCON user=$NUSR"
fi
betterguac-sync --help | grep -q -- "plan" && betterguac-sync --help | grep -q -- "apply" && pass "sync help lists plan/apply" || fail "sync help"
echo "=== RESULT pass=$PASS fail=$FAIL ==="
[ "$FAIL" = 0 ]
