#!/bin/bash
# Phase 2: upgrade the bg9 volumes to the branch image, the way a user pulls a new tag.
. ~/bgaudit-test/lib.sh
cd $T
rm -rf wt && mkdir -p wt && (cd ~/BetterGuac/wt-audit-log && git archive HEAD files yaml-sync schema) | tar -xf - -C wt
mkdir -p wt/docker/docker && cp ~/BetterGuac/wt-audit-log/docker/docker/entrypoint.sh wt/docker/docker/
docker build -q -t betterguac:audit-log-test -f Dockerfile.audit . >/dev/null && pass "test image built" || { fail "test image built"; exit 1; }

counts > $T/counts_before
docker stop -t 60 $C >/dev/null
start betterguac:audit-log-test && pass "branch image up on the bg9 volumes" || { fail "branch image up"; docker logs $C | tail -30; exit 1; }
docker exec $C grep -E "schema|migrat|backing up" /var/log/betterguac-init.log | tail -6
docker exec $C sh -c 'grep -q "applying schema change 001-audit-log" /var/log/betterguac-init.log' && pass "entrypoint applied 001-audit-log" || fail "entrypoint applied 001-audit-log"
N=$(sql -e "SELECT COUNT(*) FROM bg_schema_migration WHERE version=1 AND name='audit-log'")
[ "$N" = 1 ] && pass "bg_schema_migration records version 1" || fail "bg_schema_migration ($N)"
BK=$(docker exec $C sh -c 'ls -1 /var/lib/betterguac/backups/pre-migrate-*.sql.gz 2>/dev/null | wc -l')
[ "$BK" = 1 ] && pass "one pre-migrate backup taken" || fail "pre-migrate backups: $BK"
docker exec $C sh -c 'f=$(ls /var/lib/betterguac/backups/pre-migrate-*.sql.gz); stat -c "%a %U %s bytes" $f; zcat $f | grep -c "CREATE TABLE"; zcat $f | grep -q "guacamole_connection_history" && echo has-history; zcat $f | grep -q bg_audit_event && echo HAS-AUDIT-TABLE || echo no-audit-table'
counts > $T/counts_after
[ "$(cat $T/counts_before)" = "$(cat $T/counts_after)" ] && pass "data unchanged by the upgrade: $(cat $T/counts_after)" || fail "data changed: $(cat $T/counts_before) -> $(cat $T/counts_after)"
docker exec $C betterguac-admin migrate --status
echo "=== phase2 pass=$PASS fail=$FAIL ==="
