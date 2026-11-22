# shared helpers for the audit-log test (runs on BondLab)
set -u
T=$HOME/bgaudit-test
PORT=18090
BASE=http://127.0.0.1:$PORT/betterguac
C=bgaudit-bg
NET=bgaudit_net
VOLS="-v bgaudit_db:/var/lib/mysql -v bgaudit_conf:/etc/betterguac -v bgaudit_state:/var/lib/betterguac -v bgaudit_logs:/var/log/betterguac"
PASS=0; FAIL=0
pass(){ echo "PASS: $*"; PASS=$((PASS+1)); }
fail(){ echo "FAIL: $*"; FAIL=$((FAIL+1)); }
check(){ local msg=$1; shift; if "$@" >/dev/null 2>&1; then pass "$msg"; else fail "$msg"; fi; }
sql(){ docker exec -i $C mariadb --protocol=socket -uroot -N -B betterguac "$@"; }
start(){ # start <image>
    docker rm -f $C >/dev/null 2>&1 || true
    docker run -d --name $C --network $NET $VOLS -p 127.0.0.1:$PORT:8080 -e LANG=C.UTF-8 "$1" >/dev/null
    local i
    for i in $(seq 1 90); do
        [ "$(curl -s -o /dev/null -w '%{http_code}' $BASE/)" = 200 ] && \
        [ "$(curl -s -o /dev/null -w '%{http_code}' -X POST $BASE/api/tokens -d username=x -d password=y)" != 000 ] && return 0
        sleep 2
    done
    return 1
}
token(){ # token <user> <password> [totp]
    local extra=""
    [ -n "${3:-}" ] && extra="--data-urlencode guac-totp=$3"
    curl -s -X POST $BASE/api/tokens --data-urlencode "username=$1" --data-urlencode "password=$2" $extra \
        | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("authToken",""))' 2>/dev/null
}
api(){ # api <method> <path> <token> [json]
    if [ -n "${4:-}" ]; then
        curl -s -w '\n%{http_code}' -X "$1" "$BASE/api/session/$2" -H "Guacamole-Token: $3" -H 'Content-Type: application/json' -d "$4"
    else
        curl -s -w '\n%{http_code}' -X "$1" "$BASE/api/session/$2" -H "Guacamole-Token: $3"
    fi
}
code(){ tail -1; }
body(){ sed '$d'; }
counts(){
    sql -e "SELECT CONCAT_WS(' ', (SELECT COUNT(*) FROM guacamole_entity WHERE type='USER'), (SELECT COUNT(*) FROM guacamole_connection), (SELECT COUNT(*) FROM guacamole_connection_permission), (SELECT COUNT(*) FROM guacamole_user_group), (SELECT COUNT(*) FROM guacamole_user_attribute), (SELECT COUNT(*) FROM guacamole_connection_history))"
}
