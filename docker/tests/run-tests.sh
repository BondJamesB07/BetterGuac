#!/bin/bash
# Verification suite for the bgdocker BetterGuac container stack.
#
# Runs entirely inside this repo: docker build (if needed), a clean first boot
# from empty volumes, crash/recovery of each service, clean stop/start, and a
# down/up recreate with a canary. All raw output is written to test-results/.
#
# Usage: tests/run-tests.sh
set -uo pipefail
cd "$(dirname "$0")/.."

RES=test-results
mkdir -p "$RES"
: > "$RES/SUMMARY.txt"

pass() { echo "PASS: $*" | tee -a "$RES/SUMMARY.txt"; }
fail() { echo "FAIL: $*" | tee -a "$RES/SUMMARY.txt"; FAILED=$((FAILED+1)); }
FAILED=0
info() { echo "=== $* ===" | tee -a "$RES/SUMMARY.txt"; }

exec > >(tee -a "$RES/console.log") 2>&1

dc() { docker compose "$@"; }
insp() { docker inspect "$@"; }
code() { curl -s -o /dev/null -m 10 -w '%{http_code}' "$1" || true; }
redir() { curl -s -o /dev/null -m 10 -w '%{http_code} %{redirect_url}' "$1" || true; }

# state: wait until health is healthy/unhealthy or timeout
wait_health() {
    local want=${1:-healthy} tries=${2:-120} s start
    start=$(docker inspect -f '{{.State.StartedAt}}' bgdocker-betterguac 2>/dev/null || true)
    for i in $(seq 1 "$tries"); do
        s=$(insp -f '{{.State.Health.Status}}' bgdocker-betterguac 2>/dev/null || echo missing)
        if [ "$s" = "$want" ] && [ "$(insp -f '{{.State.StartedAt}}' bgdocker-betterguac 2>/dev/null || true)" = "$start" ]; then
            echo "health=$s (container start unchanged)" | tee -a "$RES/SUMMARY.txt"; return 0
        fi
        sleep 5
    done
    echo "health=$s (wanted $want; StartedAt changed=$([ "$(insp -f '{{.State.StartedAt}}' bgdocker-betterguac 2>/dev/null)" != "$start" ] && echo yes || echo no))" | tee -a "$RES/SUMMARY.txt"; return 1
}

get_pid() { dc exec -T betterguac sh -c "supervisorctl pid $1" 2>/dev/null | tr -d '[:space:]'; }
get_status() { dc exec -T betterguac supervisorctl status 2>/dev/null; }
ssltn() { dc exec -T betterguac ss -ltn 2>/dev/null; }

fresh_volumes() {
    dc down -v >/dev/null 2>&1 || true
    docker volume rm bgdocker_db bgdocker_conf bgdocker_state bgdocker_logs >/dev/null 2>&1 || true
}

checksums() { # sha256 of the state files that must survive, without printing contents
    dc exec -T betterguac sh -c '
        for f in /etc/betterguac/guacamole.properties /etc/betterguac/sync.env \
                 /etc/betterguac/betterguac.yaml /etc/betterguac/initial-admin.txt \
                 /etc/betterguac/guacd.conf /var/lib/betterguac/admin-user \
                 /etc/betterguac/extensions/betterguac-ui-1.6.0.jar \
                 /etc/betterguac/lib/mariadb-java-client.jar; do
            if [ -e "$f" ]; then sha256sum "$f" | sed "s|  | |"; fi
        done' | sort
}

check_services() {
    local out rc=0
    out=$(get_status)
    echo "$out" | tee -a "$RES/SUMMARY.txt"
    for p in mariadb guacd tomcat; do
        echo "$out" | grep -q "^$p .*RUNNING" || { fail "$p is not RUNNING"; rc=1; }
    done
    [ $rc = 0 ] && pass "supervisor: mariadb, guacd, tomcat RUNNING"
    return $rc
}

check_web() {
    local c r
    c=$(code http://127.0.0.1:18080/betterguac/); echo "GET /betterguac/ -> $c" | tee -a "$RES/SUMMARY.txt"
    [ "$c" = 200 ] && pass "web app 200 on /betterguac/" || fail "web app returned $c"
    r=$(redir http://127.0.0.1:18080/); echo "GET / -> $r" | tee -a "$RES/SUMMARY.txt"
    case "$r" in 30*) pass "root redirects: $r";; *) fail "root does not redirect: $r";; esac
}

check_listen() {
    local out
    out=$(ssltn)
    echo "$out" | tee -a "$RES/SUMMARY.txt"
    echo "$out" | grep -q ':3306 ' && pass "3306 listening inside" || fail "3306 not listening"
    echo "$out" | grep -q ':4822 ' && pass "4822 listening inside" || fail "4822 not listening"
    echo "$out" | grep -q ':8080 ' && pass "8080 listening inside" || fail "8080 not listening"
    docker ps --format '{{.Names}} {{.Ports}}' | grep '^bgdocker-betterguac' | tee -a "$RES/SUMMARY.txt"
}

check_admin_row() {
    local n
    n=$(dc exec -T betterguac mariadb -N -B betterguac -e \
        "SELECT COUNT(*) FROM guacamole_user u JOIN guacamole_entity e ON e.entity_id=u.entity_id WHERE e.type='USER' AND u.entity_id IN (SELECT entity_id FROM guacamole_system_permission WHERE permission='ADMINISTER')" 2>/dev/null | tr -d '[:space:]')
    echo "admin user rows: ${n:-?}" | tee -a "$RES/SUMMARY.txt"
    [ "${n:-0}" -ge 1 ] 2>/dev/null && pass "admin user row exists in betterguac DB" || fail "no admin user row (got '${n:-}')"
}

check_db_reachable() { # proof the web app can still reach the DB after mariadb restart
    local c
    # /betterguac/ is served by the app, but login page render does not hit DB.
    # A POST to the login endpoint with a bogus credential makes the app query
    # guacamole_user. 200/403/401 all mean the app talked to the DB; 500 means
    # it did not. We only record the code.
    c=$(curl -s -o /tmp/bdlogin.html -m 15 -w '%{http_code}' -X POST \
        -d 'username=__bgdocker_probe__&password=__bgdocker_probe__' \
        http://127.0.0.1:18080/betterguac/api/session 2>/dev/null || true)
    echo "login probe -> HTTP $c" | tee -a "$RES/SUMMARY.txt"
    case "$c" in
        200|401|403) pass "web app reaches DB after mariadb restart (login probe HTTP $c)";;
        *) fail "login probe returned $c (web app may not reach DB)";;
    esac
    dc exec -T betterguac sh -c 'tail -n 40 /var/log/supervisor/tomcat.log' > "$RES/tomcat-tail-after-kill.log" 2>/dev/null || true
}

kill_and_wait() { # $1=program  $2=label
    local prog=$1 label=$2 old new i st
    old=$(get_pid "$prog")
    echo "$label old pid=$old" | tee -a "$RES/SUMMARY.txt"
    dc exec -T betterguac sh -c "kill -9 $old" || true
    for i in $(seq 1 120); do
        new=$(get_pid "$prog"); st=$(dc exec -T betterguac supervisorctl status "$prog" 2>/dev/null || true)
        if [ -n "$new" ] && [ "$new" != "$old" ] && echo "$st" | grep -q RUNNING; then break; fi
        sleep 2
    done
    echo "$label new pid=$new status: $st" | tee -a "$RES/SUMMARY.txt"
    [ -n "$new" ] && [ "$new" != "$old" ] && pass "$label restarted with new pid $new" || fail "$label did not restart (old=$old new=$new)"
}

echo "===== BetterGuac bgdocker verification $(date -u '+%Y-%m-%dT%H:%M:%SZ') =====" | tee -a "$RES/SUMMARY.txt"
info "Docker before"; docker ps -a --format '{{.Names}}' | sort | tee "$RES/docker-before.txt"
echo "container count before: $(wc -l < "$RES/docker-before.txt")" | tee -a "$RES/SUMMARY.txt"

# 1. build + architecture -----------------------------------------------------
info "Step 1: build"
dc build > "$RES/02-build-compose.log" 2>&1 && pass "docker build succeeded" || fail "docker build failed"
IMAGE=betterguac:1.6.0-bg6-arm64
ARCH=$(docker image inspect -f '{{.Architecture}}' "$IMAGE" 2>/dev/null)
IID=$(docker image inspect -f '{{.Id}}' "$IMAGE" 2>/dev/null)
echo "image=$IMAGE id=$IID arch=$ARCH" | tee -a "$RES/SUMMARY.txt"
[ "$ARCH" = arm64 ] && pass "image architecture is arm64" || fail "image arch is $ARCH"

# clean first boot -----------------------------------------------------------
info "Step 2: clean first boot"
fresh_volumes
dc up -d > "$RES/03-up-first.log" 2>&1 && pass "docker compose up -d" || fail "compose up failed"
wait_health healthy 30 || fail "container never became healthy"
check_services; check_listen; check_web; check_admin_row
# init log: exactly one setup run
dc exec -T betterguac sh -c 'cat /var/log/betterguac-init.log' > "$RES/04-init-log-first-boot.txt" 2>/dev/null
grep -q 'running the package.s own setup' "$RES/04-init-log-first-boot.txt" && pass "init log shows setup ran once" || fail "init log missing setup"
grep -q 'first-run initialization complete' "$RES/04-init-log-first-boot.txt" && pass "init log shows completion" || fail "init log missing completion"
[ "$(grep -c 'running the package' "$RES/04-init-log-first-boot.txt" 2>/dev/null || echo 0)" = 1 ] && pass "setup ran exactly once" || fail "setup ran more than once"

# 3. crash recovery, one service at a time ----------------------------------
info "Step 3: crash recovery"
RC0=$(insp -f '{{.RestartCount}}' bgdocker-betterguac); SA0=$(insp -f '{{.State.StartedAt}}' bgdocker-betterguac)
echo "before: RestartCount=$RC0 StartedAt=$SA0" | tee -a "$RES/SUMMARY.txt"

kill_and_wait mariadb "mariadb"; sleep 15
check_web
kill_and_wait guacd "guacd"; sleep 5
check_web
kill_and_wait tomcat "tomcat"; sleep 20
check_web
check_db_reachable
RC1=$(insp -f '{{.RestartCount}}' bgdocker-betterguac); SA1=$(insp -f '{{.State.StartedAt}}' bgdocker-betterguac)
echo "after:  RestartCount=$RC1 StartedAt=$SA1" | tee -a "$RES/SUMMARY.txt"
[ "$RC0" = "$RC1" ] && [ "$SA0" = "$SA1" ] && pass "container never restarted (RestartCount/StartedAt unchanged)" || fail "container restarted during crash tests"

# 4. clean stop/start --------------------------------------------------------
info "Step 4: clean stop/start"
BEFORE=$(checksums); echo "$BEFORE" | sed 's/^/  /' | tee -a "$RES/SUMMARY.txt"
dc stop > "$RES/05-stop.log" 2>&1 && pass "docker compose stop" || fail "compose stop failed"
dc exec -T betterguac sh -c 'true' >/dev/null 2>&1 && fail "container still running after stop" || pass "container stopped"
dc start > "$RES/06-start.log" 2>&1 && pass "docker compose start" || fail "compose start failed"
wait_health healthy 20 || fail "not healthy after start"
check_services; check_web
AFTER=$(checksums); echo "$AFTER" | sed 's/^/  /' | tee -a "$RES/SUMMARY.txt"
[ "$BEFORE" = "$AFTER" ] && pass "checksums unchanged across stop/start" || fail "checksums changed across stop/start"
dc exec -T betterguac sh -c 'cat /var/log/betterguac-init.log' > "$RES/07-init-log-after-start.txt" 2>/dev/null
grep -q 'skipping first-run init' "$RES/07-init-log-after-start.txt" && pass "second boot skipped init (marker respected)" || fail "init was not skipped on second boot"
dc exec -T betterguac sh -c 'grep -E "Shutdown complete|ready for connections|Starting|crash recovery|InnoDB" /var/log/supervisor/mariadb.log' > "$RES/08-mariadb-log-stopstart.txt" 2>/dev/null
grep -qiE 'Shutdown complete' "$RES/08-mariadb-log-stopstart.txt" && pass "MariaDB logged a clean shutdown" || fail "no clean MariaDB shutdown in log"
grep -qiE 'crash recovery|Starting crash recovery' "$RES/08-mariadb-log-stopstart.txt" && fail "MariaDB did crash recovery" || pass "no MariaDB crash recovery"

# 5. recreate ----------------------------------------------------------------
info "Step 5: down/up recreate with canary"
C0=$(checksums)
dc exec -T betterguac mariadb -ubetterguac betterguac -e \
  "CREATE TABLE IF NOT EXISTS bgdocker_canary (id INT PRIMARY KEY, note VARCHAR(64), created_at DATETIME); INSERT INTO bgdocker_canary VALUES (1,'bgdocker-canary',NOW()) ON DUPLICATE KEY UPDATE note=VALUES(note);" \
  > "$RES/09-canary-insert.log" 2>&1 && pass "canary row inserted" || fail "canary insert failed"
dc down > "$RES/10-down.log" 2>&1 && pass "docker compose down (no -v)" || fail "compose down failed"
dc up -d > "$RES/11-up-recreate.log" 2>&1 && pass "docker compose up -d (same volumes)" || fail "compose up after down failed"
wait_health healthy 30 || fail "not healthy after recreate"
check_services; check_web; check_admin_row
AFTER=$(checksums)
[ "$C0" = "$AFTER" ] && pass "checksums unchanged across down/up" || fail "checksums changed across down/up"
CAN=$(dc exec -T betterguac mariadb -ubetterguac -N -B betterguac -e "SELECT id,note FROM bgdocker_canary WHERE id=1" 2>/dev/null | tr -d '\n')
echo "canary row: $CAN" | tee -a "$RES/SUMMARY.txt"
echo "$CAN" | grep -q 'bgdocker-canary' && pass "canary row survived down/up" || fail "canary row lost after down/up"
dc exec -T betterguac sh -c 'grep -c "skipping first-run init" /var/log/betterguac-init.log' > "$RES/12-skip-count.txt" 2>/dev/null
[ "$(cat "$RES/12-skip-count.txt")" -ge 2 ] && pass "init skipped on both restarts" || fail "init not skipped on recreate"

# 6. crash test after recreate ------------------------------------------------
info "Step 6: crash test after recreate"
RC2=$(insp -f '{{.RestartCount}}' bgdocker-betterguac); SA2=$(insp -f '{{.State.StartedAt}}' bgdocker-betterguac)
kill_and_wait mariadb "mariadb (after recreate)"; sleep 15
check_web
RC3=$(insp -f '{{.RestartCount}}' bgdocker-betterguac); SA3=$(insp -f '{{.State.StartedAt}}' bgdocker-betterguac)
echo "after-recreate crash: RestartCount $RC2 -> $RC3, StartedAt $SA2 -> $SA3" | tee -a "$RES/SUMMARY.txt"
[ "$RC2" = "$RC3" ] && [ "$SA2" = "$SA3" ] && pass "container not restarted after recreate crash" || fail "container restarted after recreate crash"

# final state ----------------------------------------------------------------
info "Final"
wait_health healthy 20 || true
check_services; check_web
docker ps -a --format '{{.Names}}' | sort > "$RES/docker-after.txt"
echo "container count after: $(wc -l < "$RES/docker-after.txt")" | tee -a "$RES/SUMMARY.txt"
diff <(grep -v '^bgdocker' "$RES/docker-before.txt") <(grep -v '^bgdocker' "$RES/docker-after.txt") > "$RES/docker-unchanged.diff" 2>&1 \
    && pass "the 12 pre-existing containers are unchanged" || fail "pre-existing container set changed"
echo | tee -a "$RES/SUMMARY.txt"
if [ "$FAILED" = 0 ]; then echo "ALL CHECKS PASSED" | tee -a "$RES/SUMMARY.txt"; exit 0
else echo "$FAILED CHECK(S) FAILED" | tee -a "$RES/SUMMARY.txt"; exit 1; fi