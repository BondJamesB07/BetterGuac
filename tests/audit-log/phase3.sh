#!/bin/bash
# Phase 3: does every kind of event land in the log, and does the API behave.
. ~/bgaudit-test/lib.sh
cd $T
ADMIN=$(cat admin_user); APW=$(cat admin_pw); CID=$(cat cid)
sql -e "DELETE FROM bg_audit_event"   # start the checks from an empty log
ev(){ # ev <action> [extra where]  -> count of rows
    sleep 0.6
    sql -e "SELECT COUNT(*) FROM bg_audit_event WHERE action='$1' ${2:-}"
}
has(){ local n; n=$(ev "$1" "${3:-}"); [ "${n:-0}" -ge 1 ] && pass "$2" || fail "$2 (no $1 row)"; }

# --- sign-ins
TK=$(token "$ADMIN" "$APW")
[ -n "$TK" ] && pass "admin signs in on the branch image" || { fail "admin sign-in"; exit 1; }
has auth.login "sign-in logged" "AND actor='$ADMIN' AND remote_addr IS NOT NULL"
token "$ADMIN" "wrong-password" >/dev/null
has auth.failed "wrong password logged as failure" "AND actor='$ADMIN' AND outcome='failure'"
token "nobody@example.com" "x" >/dev/null
has auth.failed "unknown username logged" "AND actor='nobody@example.com'"
curl -s -o /dev/null -X POST $BASE/api/tokens
N=$(sql -e "SELECT COUNT(*) FROM bg_audit_event WHERE actor IS NULL AND action='auth.failed'")
[ "$N" = 0 ] && pass "empty token requests (page loads) are not logged" || fail "empty requests logged: $N"

# --- regular user can't read the log
ATK=$(token alice@example.com Alice-Pass-12345)
[ -n "$ATK" ] && pass "alice signs in" || fail "alice sign-in"
C1=$(api GET "ext/mysql/audit/events" "$ATK" | code)
[ "$C1" = 403 ] && pass "regular user gets 403 from the activity API" || fail "regular user got $C1"
C1=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/session/ext/mysql/audit/events")
[ "$C1" = 403 ] || [ "$C1" = 401 ] && pass "no token gets $C1" || fail "no token got $C1"

# --- admin changes: users
R=$(api POST data/mysql/users "$TK" '{"username":"bob@example.com","password":"Bob-Pass-123456","attributes":{"guac-totp-disabled":"true","guac-email-address":"bob@example.com","bg-first-name":"Bob","bg-last-name":"Tester"}}')
[ "$(echo "$R" | code)" = 200 ] || fail "create bob: $(echo "$R" | tail -c 200)"
has user.created "user added logged" "AND target_name='bob@example.com' AND actor='$ADMIN'"
R=$(api PUT data/mysql/users/bob@example.com "$TK" '{"username":"bob@example.com","password":"Bob-New-Pass-99","attributes":{"guac-totp-disabled":"true","guac-email-address":"bob@example.com","bg-first-name":"Robert","bg-last-name":"Tester"}}')
[ "$(echo "$R" | code)" = 204 ] || fail "update bob: $(echo "$R" | tail -c 200)"
has user.updated "user change logged, with password change noted" "AND target_name='bob@example.com' AND detail LIKE '%Password changed%'"
R=$(api PATCH data/mysql/users/bob@example.com/permissions "$TK" "[{\"op\":\"add\",\"path\":\"/connectionPermissions/$CID\",\"value\":\"READ\"}]")
[ "$(echo "$R" | code)" = 204 ] || fail "grant: $(echo "$R" | tail -c 200)"
has permission.granted "server access granted logged, with server name" "AND target_name='bob@example.com' AND detail LIKE '%ssh-target%'"
R=$(api PATCH data/mysql/users/bob@example.com/permissions "$TK" "[{\"op\":\"remove\",\"path\":\"/connectionPermissions/$CID\",\"value\":\"READ\"}]")
has permission.revoked "server access removed logged" "AND target_name='bob@example.com'"
R=$(api PATCH data/mysql/users/bob@example.com/permissions "$TK" '[{"op":"add","path":"/systemPermissions","value":"ADMINISTER"}]')
has user.role_changed "admin role granted logged" "AND target_name='bob@example.com' AND detail='Admin role granted'"
R=$(api PATCH data/mysql/users/bob@example.com/userGroups "$TK" '[{"op":"add","path":"/","value":"Servers: Lab"}]')
[ "$(echo "$R" | code)" = 204 ] || fail "group add: $(echo "$R" | tail -c 200)"
has group.member_added "added to group logged" "AND target_name='Servers: Lab' AND detail LIKE '%bob@example.com%'"
R=$(api PATCH "data/mysql/userGroups/Servers%3A%20Lab/memberUsers" "$TK" '[{"op":"remove","path":"/","value":"bob@example.com"}]')
has group.member_removed "removed from group (from the group side) logged" "AND target_name='Servers: Lab'"
R=$(api PATCH "data/mysql/userGroups/Servers%3A%20Lab/permissions" "$TK" "[{\"op\":\"add\",\"path\":\"/connectionPermissions/$CID\",\"value\":\"READ\"}]")
has permission.granted "group gets server access logged" "AND target_type='group' AND target_name='Servers: Lab'"

# --- servers and groups
R=$(api POST data/mysql/connections "$TK" '{"parentIdentifier":"ROOT","name":"temp-server","protocol":"vnc","parameters":{"hostname":"192.0.2.9","port":"5900"},"attributes":{}}')
TID=$(echo "$R" | body | python3 -c 'import json,sys; print(json.load(sys.stdin)["identifier"])' 2>/dev/null)
has server.created "server added logged" "AND target_name='temp-server' AND detail LIKE 'VNC%'"
R=$(api PUT data/mysql/connections/$TID "$TK" '{"parentIdentifier":"ROOT","name":"temp-server-2","protocol":"vnc","parameters":{"hostname":"192.0.2.9","port":"5901"},"attributes":{}}')
has server.updated "server change logged" "AND target_name='temp-server-2'"
R=$(api DELETE data/mysql/connections/$TID "$TK")
has server.deleted "server delete logged, with its name" "AND target_id='$TID' AND target_name='temp-server-2'"
R=$(api POST data/mysql/userGroups "$TK" '{"identifier":"Temp group","attributes":{}}')
has group.created "group added logged" "AND target_name='Temp group'"
R=$(api DELETE "data/mysql/userGroups/Temp%20group" "$TK")
has group.deleted "group delete logged" "AND target_name='Temp group'"
R=$(api DELETE data/mysql/users/bob@example.com "$TK")
has user.deleted "user delete logged" "AND target_name='bob@example.com'"
N=$(sql -e "SELECT COUNT(*) FROM bg_audit_event WHERE action LIKE 'user.%' AND actor IS NULL")
[ "$N" = 0 ] && pass "every admin change names who did it" || fail "$N admin rows without an actor"

# --- MFA: a user with two-factor on
R=$(api POST data/mysql/users "$TK" '{"username":"carol@example.com","password":"Carol-Pass-12345","attributes":{"guac-email-address":"carol@example.com","bg-first-name":"Carol","bg-last-name":"Tester"}}')
token carol@example.com Carol-Pass-12345 >/dev/null
has mfa.enroll_prompt "two-factor setup prompt logged" "AND actor='carol@example.com'"
token carol@example.com Carol-Pass-12345 000000 >/dev/null
has mfa.failed "wrong two-factor code logged as failure" "AND actor='carol@example.com' AND outcome='failure'"
SECRET=$(sql -e "SELECT attribute_value FROM guacamole_user_attribute a JOIN guacamole_user u ON u.user_id=a.user_id JOIN guacamole_entity e ON e.entity_id=u.entity_id WHERE e.name='carol@example.com' AND attribute_name='guac-totp-key-secret'")
if [ -n "$SECRET" ]; then
    CODE=$(python3 -c "
import base64,hmac,hashlib,struct,time,sys
s='$SECRET'; s+= '=' * (-len(s) % 8)
k=base64.b32decode(s.upper()); c=int(time.time())//30
h=hmac.new(k,struct.pack('>Q',c),hashlib.sha1).digest(); o=h[-1]&15
print('%06d' % ((struct.unpack('>I',h[o:o+4])[0]&0x7fffffff)%1000000))")
    CTK=$(token carol@example.com Carol-Pass-12345 "$CODE")
    [ -n "$CTK" ] && pass "carol enrolls with a real code" || fail "carol enroll with code"
    has auth.login "sign-in with two-factor code logged as such" "AND actor='carol@example.com' AND detail LIKE '%two-factor%'"
else
    fail "carol has no TOTP secret to test with"
fi
R=$(api POST ext/mysql/mfa/reset-user "$TK" '{"username":"carol@example.com"}')
[ "$(echo "$R" | code)" = 200 ] || fail "reset-user: $(echo "$R" | tail -c 200)"
has mfa.reset_user "admin two-factor reset logged" "AND target_name='carol@example.com' AND actor='$ADMIN'"

# --- sign-out
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "$BASE/api/tokens/$ATK")
has auth.logout "sign-out logged" "AND actor='alice@example.com'"

# --- a real session on a server (from Guacamole's own history)
ATK=$(token alice@example.com Alice-Pass-12345)
H0=$(sql -e "SELECT COUNT(*) FROM guacamole_connection_history")
timeout 60 python3 tunnel.py "$BASE" "$ATK" "$CID" 3 | grep -E "tunnel|DONE" | sed 's/^/  /'
# Guacamole writes end_date when its side of the tunnel closes (about 10 s later)
for i in $(seq 1 30); do
    H1=$(sql -e "SELECT COUNT(*) FROM guacamole_connection_history WHERE username='alice@example.com' AND end_date IS NOT NULL AND history_id > (SELECT COALESCE(MAX(history_id),0) FROM guacamole_connection_history) - 1")
    [ "$H1" -ge 1 ] && break; sleep 1
done
echo "  end_date written after about $i s"
docker logs bgaudit-ssh 2>&1 | grep -c "Accepted password for tester" | xargs -I{} echo "  sshd accepted logins so far: {}"
R=$(api GET "ext/mysql/audit/events?category=session&actor=alice@example.com" "$TK")
echo "$R" | body | python3 -c '
import json,sys; d=json.load(sys.stdin)
for e in d["events"][:4]: print("  ", e["action"], e["targetName"], e["detail"], e["remoteAddr"])
acts=[e["action"] for e in d["events"]]
sys.exit(0 if "session.start" in acts and "session.end" in acts else 1)' && pass "alice's session shows as start and end on server ssh-target" || fail "session rows missing (history rows for alice: $H1)"

# --- YAML sync apply
INST=$(docker exec $C betterguac-sync status 2>/dev/null | awk '/^instance/{print $2}')
docker exec -i $C sh -c 'cat > /tmp/audit.yaml' <<EOF
version: 1
kind: guacamole-db-sync
instance: $INST
connections:
  - key: yaml-web
    name: YAML-Web
    protocol: ssh
    params:
      hostname: 192.0.2.44
      port: 22
      username: admin
users: []
EOF
PLAN=$(docker exec $C betterguac-sync plan /tmp/audit.yaml 2>&1 | grep -oE '[0-9a-f]{12,}' | tail -1)
OUT=$(docker exec $C betterguac-sync apply /tmp/audit.yaml --confirm "$PLAN" 2>&1); echo "$OUT" | tail -3 | sed 's/^/  /'
has sync.applied "YAML apply logged (summary row)" "AND source='yaml-sync'"
has sync.create "YAML apply logged per change" "AND target_name='YAML-Web'"

# --- the API: filters, search, paging, CSV, retention
q(){ api GET "ext/mysql/audit/events?$1" "$TK" | body; }
N=$(q "category=auth&outcome=failure" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(int(all(e["outcome"]=="failure" and e["category"]=="auth" for e in d["events"]) and d["total"]>=2))')
[ "$N" = 1 ] && pass "filter by kind and result" || fail "category/outcome filter"
N=$(q "q=ssh-target" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["total"])')
[ "${N:-0}" -ge 3 ] && pass "search finds rows by server name ($N)" || fail "search ($N)"
N=$(q "q=%25" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["total"])')
[ "$N" = 0 ] && pass "a % in search is matched literally" || fail "wildcard leaked ($N)"
P=$(q "limit=5&offset=0" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d["events"]), d["total"], d["events"][0]["time"] >= d["events"][-1]["time"])')
echo "  page 1: $P"
set -- $P; [ "$1" = 5 ] && [ "$3" = True ] && pass "paging, newest first (total $2)" || fail "paging $P"
N=$(q "from=2000-01-01&to=2000-01-02" | python3 -c 'import json,sys; print(json.load(sys.stdin)["total"])')
[ "$N" = 0 ] && pass "date range filter" || fail "date range ($N)"
C1=$(api GET "ext/mysql/audit/events?category=bogus" "$TK" | code)
[ "$C1" = 400 ] && pass "unknown category refused (400)" || fail "bogus category got $C1"

sql -e "INSERT INTO bg_audit_event (event_time,category,action,outcome,actor,detail) VALUES (NOW(),'auth','auth.failed','failure','=cmd|evil','a,b \"q\"')"
curl -s -D $T/csv.h -o $T/export.csv "$BASE/api/session/ext/mysql/audit/export?category=auth" -H "Guacamole-Token: $TK"
grep -qi 'content-disposition: attachment; filename="betterguac-activity-' $T/csv.h && pass "CSV downloads as a file" || fail "CSV header"
head -1 $T/export.csv | grep -q '^time,category,action,outcome,user,from,target_type,target,detail,source' && pass "CSV header row" || fail "CSV header row"
grep -q "'=cmd|evil" $T/export.csv && pass "CSV defuses spreadsheet formulas" || fail "formula not escaped"
grep -q '"a,b ""q"""' $T/export.csv && pass "CSV quotes commas and quotes" || fail "CSV quoting"
python3 -c "import csv; r=list(csv.reader(open('$T/export.csv'))); assert all(len(x)==10 for x in r), set(len(x) for x in r); print('  CSV rows:', len(r)-1)" && pass "CSV parses with 10 columns on every row" || fail "CSV parse"
has audit.exported "the export itself is logged" "AND actor='$ADMIN'"

S=$(api GET ext/mysql/audit/settings "$TK" | body); echo "  settings: $S"
echo "$S" | grep -q '"retentionDays":365' && pass "default retention 365 days" || fail "default retention"
C1=$(api PUT ext/mysql/audit/settings "$TK" '{"retentionDays":3,"sessionRetentionDays":0}' | code)
[ "$C1" = 400 ] && pass "retention under 7 days refused" || fail "retention 3 got $C1"
C1=$(api PUT ext/mysql/audit/settings "$TK" '{"retentionDays":30,"sessionRetentionDays":0}' | code)
[ "$C1" = 200 ] && pass "retention set to 30 days" || fail "retention 30 got $C1"
has audit.settings_changed "retention change logged" "AND detail LIKE '%365 days -> 30 days%'"
sql -e "INSERT INTO bg_audit_event (event_time,category,action,outcome,actor) VALUES (NOW() - INTERVAL 40 DAY,'auth','auth.login','success','old@example.com')"
R=$(api POST ext/mysql/audit/purge "$TK" | body); echo "  purge: $R"
N=$(sql -e "SELECT COUNT(*) FROM bg_audit_event WHERE actor='old@example.com'")
[ "$N" = 0 ] && pass "purge deletes rows past retention" || fail "old row survived"
N=$(sql -e "SELECT COUNT(*) FROM guacamole_connection_history")
[ "$N" -ge 1 ] && pass "session history kept (its retention is 0 = forever)" || fail "history emptied"
has audit.purged "purge logged"
C1=$(api PUT ext/mysql/audit/settings "$ATK" '{"retentionDays":0,"sessionRetentionDays":0}' | code)
[ "$C1" = 403 ] && pass "regular user can't change retention" || fail "alice retention got $C1"

# --- the page is in the web app
curl -s "$BASE/app.js" | grep -q bgActivityController && pass "Activity page code is served to the browser" || fail "activity js not in app.js"
curl -s "$BASE/app.css" | grep -q bg-act-row && pass "Activity page styles are served" || fail "activity css not in app.css"

echo "--- rows by action ---"
sql -e "SELECT action, COUNT(*) FROM bg_audit_event GROUP BY action ORDER BY action" | sed 's/^/  /'
docker exec $C sh -c 'grep -i "activity log\|AuditListener\|betterguac-audit" /var/log/tomcat*/catalina*.log /var/log/betterguac/*.log 2>/dev/null | tail -5'
echo "=== phase3 pass=$PASS fail=$FAIL ==="
