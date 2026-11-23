#!/bin/bash
# Docker HEALTHCHECK. Reports; it does not restart anything (supervisord does
# that for individual programs, compose restart: unless-stopped for the whole
# container). Checks: web app 200, guacd 4822, MariaDB ping.
set -uo pipefail
fail() { echo "unhealthy: $*"; exit 1; }

# plain HTTP/1.0 request through bash's /dev/tcp (the image has no curl);
# only the status code of the first response line is used, redirects are not followed
code=$(timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/8080 || exit 1
printf "GET /betterguac/ HTTP/1.0\r\nHost: 127.0.0.1:8080\r\nConnection: close\r\n\r\n" >&3
read -r _ c _ <&3 && printf "%s" "$c"' 2>/dev/null || true)
[ "$code" = 200 ] || fail "web app /betterguac/ returned ${code:-no response}"

if [ ! -S /run/mysqld/mysqld.sock ]; then
    # MariaDB also listens on 127.0.0.1:3306; the socket is the primary check
    mariadb-admin --protocol=socket -uroot ping >/dev/null 2>&1 \
        || fail "MariaDB ping failed"
fi

timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/4822' 2>/dev/null \
    || fail "guacd port 4822 not listening"

echo "ok: web 200, guacd 4822, mariadb ping"
exit 0