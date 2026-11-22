#!/bin/bash
# Readiness wrapper. Blocks until MariaDB answers on its Unix socket, then
# replaces itself with the real program. Supervisor uses this so that the web
# app and guacd never start before the database (supervisor priorities alone
# are not readiness).
set -euo pipefail
SOCK=/run/mysqld/mysqld.sock
LOG=/var/log/wait-for-db.log

for i in $(seq 1 "${DB_WAIT_TRIES:-180}"); do
    if mariadb-admin --protocol=socket -uroot ping >/dev/null 2>&1; then
        echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') mariadb is answering after ${i}s" >>"$LOG"
        exec "$@"
    fi
    sleep 1
done
echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') ERROR: mariadb did not answer on $SOCK" >>"$LOG"
exit 1