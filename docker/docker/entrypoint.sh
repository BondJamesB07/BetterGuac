#!/bin/bash
# First-run initialization for BetterGuac without systemd.
#
#   * empty /var/lib/betterguac -> full init: MariaDB datadir, temp MariaDB,
#     the package's own betterguac-setup (database, schema, admin account, YAML
#     sync, Tomcat context), clean shutdown, marker.
#   * marker present -> no init at all; go straight to supervisord.
#   * half-finished init (datadir seeded or /var/lib/betterguac populated, no
#     marker) -> refuse to touch anything and say what to do.
#
# It is safe to run the init steps again: every betterguac-setup step is
# idempotent ("never overwrites settings, accounts or data that already
# exist"), which is what makes recovery from an interrupted first boot work.
set -euo pipefail

CONF=/etc/betterguac
STATE=/var/lib/betterguac
DATADIR=/var/lib/mysql
SOCK=/run/mysqld/mysqld.sock
MARKER=$STATE/.initialized
INITLOG=/var/log/betterguac-init.log
PKG_SHARE=/usr/share/betterguac

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" | tee -a "$INITLOG"; }
die() { log "ERROR: $*"; exit 1; }

# ---------------------------------------------------------------- config seeding
# A named volume mounted at /etc/betterguac hides everything the image ships
# there. Copy it in once (marker file: /var/lib/betterguac/.config-seeded).
if [ ! -e "$STATE/.config-seeded" ]; then
    if [ ! -f "$CONF/guacd.conf" ]; then
        cp -a /etc/betterguac/. "$CONF"/
        log "seeded $CONF from the image"
    fi
    # (Re)create the extension/jar symlinks the package ships. They point at
    # the Tomcat 10 copy in /var/cache/betterguac, which betterguac-tomcat-run
    # prepares (it also repairs the links in volumes from older images).
    for jar in "$PKG_SHARE"/javaee/extensions/*.jar; do
        ln -sfn "/var/cache/betterguac/extensions/$(basename "$jar")" "$CONF/extensions/$(basename "$jar")"
    done
    ln -sfn /usr/share/java/mariadb-java-client.jar "$CONF/lib/mariadb-java-client.jar"
    : > "$STATE/.config-seeded"
fi

# ------------------------------------------------------------- first run vs. skip
# Marker present: no first-run init, but a newer image may carry database
# schema changes (betterguac-setup migrate: backup first, idempotent, a no-op
# when the schema is current). BETTERGUAC_SKIP_MIGRATE=1 skips it.
UPGRADE=0
if [ -e "$MARKER" ]; then
    log "initialized marker found at $MARKER: skipping first-run init"
    if [ "${BETTERGUAC_SKIP_MIGRATE:-0}" = 1 ] || [ ! -d /usr/share/betterguac/schema/betterguac ]; then
        exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf -n
    fi
    UPGRADE=1
fi

# Half-initialized: datadir or state present but no marker -> do not guess.
if [ "$UPGRADE" = 0 ] && { [ -d "$DATADIR/mysql" ] || [ -d "$DATADIR/betterguac" ] || [ -n "$(ls -A "$STATE" 2>/dev/null | grep -v -x -e '.config-seeded' || true)" ]; }; then
    log "ERROR: found MariaDB data in $DATADIR or state in $STATE but no $MARKER."
    log "ERROR: a previous first boot did not finish. Nothing was changed. To retry:"
    log "ERROR:   docker compose down -v   # deletes the betterguac_* volumes (data loss)"
    log "ERROR:   docker compose up -d"
    exit 1
fi

# ------------------------------------------------------------- MariaDB datadir
install -d -m 0755 /run/mysqld
if [ ! -d "$DATADIR/mysql" ]; then
    log "initializing a new MariaDB datadir in $DATADIR"
    mariadb-install-db --user=mysql --datadir="$DATADIR" --auth-root-authentication-method=normal >>"$INITLOG" 2>&1
fi

log "starting a temporary MariaDB for setup"
mariadbd --user=mysql --datadir="$DATADIR" --socket="$SOCK" --bind-address=127.0.0.1 \
    --skip-networking=0 --pid-file=/run/mysqld/mysqld.pid >>/var/log/mariadb-init.log 2>&1 &
TMP_PID=$!
cleanup() {
    kill -TERM "$TMP_PID" 2>/dev/null || true
    for i in $(seq 1 60); do
        kill -0 "$TMP_PID" 2>/dev/null || break
        sleep 1
    done
    kill -KILL "$TMP_PID" 2>/dev/null || true
}
trap cleanup EXIT

ready=0
for i in $(seq 1 90); do
    if mariadb-admin --protocol=socket -uroot ping >/dev/null 2>&1; then ready=1; break; fi
    sleep 1
done
[ "$ready" = 1 ] || die "temporary MariaDB did not answer on $SOCK"
log "temporary MariaDB is answering"

if [ "$UPGRADE" = 1 ]; then
    log "checking for database schema changes: /usr/lib/betterguac/betterguac-setup migrate"
    if /usr/lib/betterguac/betterguac-setup migrate 2>&1 | tee -a "$INITLOG"; then
        log "database schema is current"
    else
        die "schema migration failed; the database was backed up first (see /var/lib/betterguac/backups). To start without migrating: BETTERGUAC_SKIP_MIGRATE=1"
    fi
    cleanup
    trap - EXIT
    exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf -n
fi

# ------------------------------------------------- run the package's own setup
# Non-interactive: no debconf admin email/password -> the package generates a
# strong random admin password and writes it to
# /etc/betterguac/initial-admin.txt (mode 0600, root only).
log "running the package's own setup: /usr/lib/betterguac/betterguac-setup configure"
if /usr/lib/betterguac/betterguac-setup configure >>"$INITLOG" 2>&1; then
    log "betterguac-setup configure succeeded"
else
    rc=$?
    die "betterguac-setup configure failed (exit $rc); see $INITLOG"
fi

# Sanity: the admin account and the config files must exist before we mark ready.
mariadb --protocol=socket -uroot -N -B betterguac -e \
    "SELECT COUNT(*) FROM guacamole_system_permission WHERE permission='ADMINISTER'" | grep -q '^[1-9]' \
    || die "no administrator row was created"
for f in "$CONF/guacamole.properties" "$CONF/sync.env" "$CONF/betterguac.yaml" "$CONF/initial-admin.txt"; do
    [ -s "$f" ] || die "expected $f to exist after setup"
done
log "admin account and configuration verified"

# ------------------------------------------------------------ clean shutdown
log "shutting the temporary MariaDB down cleanly"
cleanup
trap - EXIT
log "temporary MariaDB stopped"

: > "$MARKER"
log "first-run initialization complete (marker: $MARKER)"
exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf -n