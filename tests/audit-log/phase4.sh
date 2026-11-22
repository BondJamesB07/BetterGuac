#!/bin/bash
# Phase 4: restarts and re-runs change nothing; a fresh install gets the schema too.
. ~/bgaudit-test/lib.sh
cd $T
docker stop -t 60 $C >/dev/null
start betterguac:audit-log-test && pass "rebuilt image up on the same volumes" || { fail "restart"; exit 1; }
BK=$(docker exec $C sh -c 'ls -1 /var/lib/betterguac/backups/pre-migrate-*.sql.gz | wc -l')
[ "$BK" = 1 ] && pass "restart with nothing new: no second backup" || fail "backups now $BK"
docker exec $C sh -c 'tail -4 /var/log/betterguac-init.log' | grep -q "database schema is up to date" && pass "restart says the schema is up to date" || fail "restart log"
OUT=$(docker exec $C betterguac-admin migrate 2>&1); echo "  $OUT"
echo "$OUT" | grep -q "up to date" && pass "betterguac-admin migrate again: nothing to do" || fail "migrate again"
docker exec $C sh -c 'mariadb --protocol=socket -uroot betterguac < /usr/share/betterguac/schema/betterguac/001-audit-log.sql' && pass "001-audit-log.sql run twice by hand: no error" || fail "001 not idempotent"
N=$(sql -e "SELECT COUNT(*) FROM bg_setting WHERE name='audit.retention-days' AND value='30'")
[ "$N" = 1 ] && pass "re-running it kept the admin's retention setting (30)" || fail "retention reset by re-run"
# a changed migration file is noticed, not re-applied
docker exec $C sh -c 'echo "-- edited" >> /usr/share/betterguac/schema/betterguac/001-audit-log.sql'
docker exec $C betterguac-admin migrate 2>&1 | grep -q "was edited after it was applied" && pass "an edited migration is flagged, not re-run" || fail "edited migration not flagged"
docker exec $C sh -c 'sed -i "\$d" /usr/share/betterguac/schema/betterguac/001-audit-log.sql'
# a fake 002 shows the ordering and backup on a later upgrade
docker exec $C sh -c 'printf "CREATE TABLE IF NOT EXISTS bg_test_002 (id INT PRIMARY KEY);\n" > /usr/share/betterguac/schema/betterguac/002-test.sql'
docker exec $C betterguac-admin migrate 2>&1 | sed 's/^/  /'
N=$(sql -e "SELECT GROUP_CONCAT(version ORDER BY version) FROM bg_schema_migration")
BK=$(docker exec $C sh -c 'ls -1 /var/lib/betterguac/backups/pre-migrate-*.sql.gz | wc -l')
[ "$N" = "1,2" ] && [ "$BK" = 2 ] && pass "a later 002 applies after its own backup" || fail "002: versions $N backups $BK"
docker exec $C sh -c 'rm /usr/share/betterguac/schema/betterguac/002-test.sql'
sql -e "DROP TABLE bg_test_002; DELETE FROM bg_schema_migration WHERE version=2"
# a broken migration stops with the backup named, and is not recorded
docker exec $C sh -c 'printf "CREATE TABLE broken (;\n" > /usr/share/betterguac/schema/betterguac/003-broken.sql'
OUT=$(docker exec $C betterguac-admin migrate 2>&1); RC=$?
echo "$OUT" | tail -2 | sed 's/^/  /'
N=$(sql -e "SELECT COUNT(*) FROM bg_schema_migration WHERE version=3")
[ $RC -ne 0 ] && [ "$N" = 0 ] && echo "$OUT" | grep -q "pre-migrate-" && pass "a failing migration exits non-zero, isn't recorded, and names the backup" || fail "broken migration rc=$RC recorded=$N"
docker exec $C sh -c 'rm /usr/share/betterguac/schema/betterguac/003-broken.sql'
docker exec $C sh -c 'ls -1t /var/lib/betterguac/backups/ | head -1 | xargs -I{} rm /var/lib/betterguac/backups/{}'
docker exec $C sh -c 'ls -1t /var/lib/betterguac/backups/ | head -1 | xargs -I{} rm /var/lib/betterguac/backups/{}'

# restore drill: the pre-migrate dump brings back a bg9-shaped database
RB=$(docker exec $C sh -c 'ls -1 /var/lib/betterguac/backups/pre-migrate-*.sql.gz | head -1')
docker rm -f bgaudit-restore >/dev/null 2>&1; docker run -d --name bgaudit-restore -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 mariadb:lts >/dev/null
for i in $(seq 1 90); do docker exec bgaudit-restore mariadb -uroot -e 'SELECT 1' >/dev/null 2>&1 && break; sleep 2; done
docker exec $C cat "$RB" | gunzip | docker exec -i bgaudit-restore mariadb -uroot
R=$(docker exec bgaudit-restore mariadb -uroot -N -B betterguac -e "SELECT CONCAT((SELECT COUNT(*) FROM guacamole_entity WHERE type='USER'),' ',(SELECT COUNT(*) FROM guacamole_connection),' ',(SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='betterguac' AND table_name LIKE 'bg\_%'))")
echo "  restored: users servers bg_tables = $R"
[ "$R" = "2 1 1" ] && pass "pre-migrate backup restores the bg9 database (2 users, 1 server, only the empty migration table)" || fail "restore drill: $R"
docker rm -f bgaudit-restore >/dev/null

# fresh install on the branch image
docker rm -f bgaudit-fresh >/dev/null 2>&1; for v in fdb fconf fstate flogs; do docker volume rm bgaudit_$v >/dev/null 2>&1; done
docker run -d --name bgaudit-fresh -v bgaudit_fdb:/var/lib/mysql -v bgaudit_fconf:/etc/betterguac -v bgaudit_fstate:/var/lib/betterguac -v bgaudit_flogs:/var/log/betterguac -p 127.0.0.1:18091:8080 betterguac:audit-log-test >/dev/null
for i in $(seq 1 90); do [ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18091/betterguac/)" = 200 ] && break; sleep 2; done
sleep 3
N=$(docker exec bgaudit-fresh mariadb --protocol=socket -uroot -N -B betterguac -e "SELECT COUNT(*) FROM bg_schema_migration WHERE version=1" 2>&1)
BK=$(docker exec bgaudit-fresh sh -c 'ls /var/lib/betterguac/backups 2>/dev/null | wc -l')
[ "$N" = 1 ] && [ "$BK" = 0 ] && pass "fresh install: schema 001 applied, no backup needed" || fail "fresh: migration=$N backups=$BK"
FU=$(docker exec bgaudit-fresh sed -n 's/^username: //p' /etc/betterguac/initial-admin.txt)
FP=$(docker exec bgaudit-fresh sed -n 's/^password: //p' /etc/betterguac/initial-admin.txt)
FT=$(curl -s -X POST http://127.0.0.1:18091/betterguac/api/tokens --data-urlencode "username=$FU" --data-urlencode "password=$FP" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("authToken",""))' 2>/dev/null)
[ -n "$FT" ] && pass "fresh install: setup admin signs in" || fail "fresh admin sign-in"
sleep 1
N=$(curl -s "http://127.0.0.1:18091/betterguac/api/session/ext/mysql/audit/events" -H "Guacamole-Token: $FT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["events"][0]["action"])' 2>&1)
[ "$N" = auth.login ] && pass "fresh install: its first sign-in is in the log" || fail "fresh log: $N"
docker exec bgaudit-fresh sh -c 'grep -E "schema" /var/log/betterguac-init.log' | sed 's/^/  /'
echo "=== phase4 pass=$PASS fail=$FAIL ==="
