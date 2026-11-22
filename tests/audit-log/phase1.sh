#!/bin/bash
# Phase 1: a bg9 install with some data, the way an existing user has it.
. ~/bgaudit-test/lib.sh
docker network create $NET >/dev/null 2>&1 || true
# SSH target for real sessions
docker rm -f bgaudit-ssh >/dev/null 2>&1 || true
docker run -d --name bgaudit-ssh --network $NET debian:trixie bash -c '
  export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq openssh-server >/dev/null &&
  useradd -m -s /bin/bash tester && echo tester:Tester-Pass-123 | chpasswd && mkdir -p /run/sshd &&
  sed -i "s/^#\?PasswordAuthentication.*/PasswordAuthentication yes/" /etc/ssh/sshd_config && exec /usr/sbin/sshd -D -e' >/dev/null
docker rm -f $C bgaudit-fresh >/dev/null 2>&1
for v in db conf state logs; do docker volume rm bgaudit_$v >/dev/null 2>&1 || true; done

start bondjamesb07/betterguac:1.6.0-bg9 && pass "bg9 container up" || { fail "bg9 container up"; docker logs $C | tail -20; exit 1; }
ADMIN=$(docker exec $C sed -n 's/^username: //p' /etc/betterguac/initial-admin.txt)
APW=$(docker exec $C sed -n 's/^password: //p' /etc/betterguac/initial-admin.txt)
echo "$ADMIN" > $T/admin_user; echo "$APW" > $T/admin_pw; chmod 600 $T/admin_pw
TK=$(token "$ADMIN" "$APW")
[ -n "$TK" ] && pass "bg9 admin sign-in" || fail "bg9 admin sign-in"

# a server, a user with access to it, a group
R=$(api POST data/mysql/connections "$TK" '{"parentIdentifier":"ROOT","name":"ssh-target","protocol":"ssh","parameters":{"hostname":"bgaudit-ssh","port":"22","username":"tester","password":"Tester-Pass-123"},"attributes":{}}')
[ "$(echo "$R" | code)" = 200 ] && pass "bg9: server created" || fail "bg9: server created ($(echo "$R" | tail -c 300))"
CID=$(echo "$R" | body | python3 -c 'import json,sys; print(json.load(sys.stdin)["identifier"])')
echo "$CID" > $T/cid
R=$(api POST data/mysql/users "$TK" '{"username":"alice@example.com","password":"Alice-Pass-12345","attributes":{"guac-totp-disabled":"true","guac-email-address":"alice@example.com","bg-first-name":"Alice","bg-last-name":"Tester"}}')
[ "$(echo "$R" | code)" = 200 ] && pass "bg9: user alice created" || fail "bg9: user alice ($(echo "$R" | tail -c 300))"
R=$(api PATCH data/mysql/users/alice@example.com/permissions "$TK" "[{\"op\":\"add\",\"path\":\"/connectionPermissions/$CID\",\"value\":\"READ\"}]")
[ "$(echo "$R" | code)" = 204 ] && pass "bg9: alice given ssh-target" || fail "bg9: alice permission ($(echo "$R" | tail -c 300))"
R=$(api POST data/mysql/userGroups "$TK" '{"identifier":"Servers: Lab","attributes":{}}')
[ "$(echo "$R" | code)" = 200 ] && pass "bg9: group created" || fail "bg9: group ($(echo "$R" | tail -c 300))"
counts > $T/counts_before
echo "counts (users servers conn-perms groups user-attrs history): $(cat $T/counts_before)"
sql -e "SHOW TABLES LIKE 'bg\_%'" | wc -l | xargs -I{} echo "bg_ tables before upgrade: {}"
echo "=== phase1 pass=$PASS fail=$FAIL ==="
