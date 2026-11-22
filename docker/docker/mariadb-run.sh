#!/bin/bash
# Run the real mariadbd in the foreground as the mysql user (not mariadbd-safe,
# which double-forks). Supervisor owns this PID and can signal/stop it.
set -euo pipefail
mkdir -p /run/mysqld
chown mysql:mysql /run/mysqld
exec /usr/sbin/mariadbd --user=mysql \
    --datadir=/var/lib/mysql \
    --socket=/run/mysqld/mysqld.sock \
    --pid-file=/run/mysqld/mysqld.pid \
    --bind-address=127.0.0.1