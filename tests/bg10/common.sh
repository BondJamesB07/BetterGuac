# shared helpers, sourced inside the systemd test container
PASS=0; FAIL=0
pass(){ echo "PASS: $*"; PASS=$((PASS+1)); }
fail(){ echo "FAIL: $*"; FAIL=$((FAIL+1)); }
sql(){ mariadb --protocol=socket -uroot -N -B betterguac "$@"; }
admin_user(){ sed -n 's/^username: //p' /etc/betterguac/initial-admin.txt; }
admin_pw(){ sed -n 's/^password: //p' /etc/betterguac/initial-admin.txt; }
login_code(){ curl -s -o /dev/null -w '%{http_code}' --max-time 20 -X POST http://127.0.0.1:8080/betterguac/api/tokens --data-urlencode "username=$1" --data-urlencode "password=$2"; }
wait_web(){ for i in $(seq 1 90); do c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8080/betterguac/); [ "$c" = 200 ] && return 0; sleep 2; done; return 1; }
setup_tester(){
  export DEBIAN_FRONTEND=noninteractive
  command -v sudo >/dev/null || { apt-get update -qq >/dev/null; apt-get install -y -qq sudo >/dev/null; }
  id tester >/dev/null 2>&1 || useradd -m -s /bin/bash tester
  echo 'tester ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/tester; chmod 440 /etc/sudoers.d/tester
}
# run the Linux install commands exactly as copied from https://betterguac.org (answering apt's prompt with y)
run_page_cmds(){
  cp /root/linuxCmd.sh /home/tester/linuxCmd.sh; chown tester: /home/tester/linuxCmd.sh
  su - tester -c 'cd ~ && yes | bash ./linuxCmd.sh' > /root/pagecmd.log 2>&1; local rc=$?
  echo "page commands rc=$rc"; grep -E ': OK|FAILED|Setting up betterguac|Unpacking betterguac|username:|E: ' /root/pagecmd.log | sed 's/^password: .*/password: <hidden>/' | grep -v '^password' 
  return $rc
}
probes(){
  local U P; U=$(admin_user); P=$(admin_pw)
  for proto in rdp vnc; do
    if [ $proto = rdp ]; then port=3389; else port=5901; fi
    python3 /root/probe.py guacd $proto "$TARGET" $port probe "$TPW" && pass "guacd $proto session to target streamed the desktop" || fail "guacd $proto session"
    python3 /root/probe.py web $proto "$TARGET" $port probe "$TPW" "$U" "$P" && pass "web app $proto connection (REST API + HTTP tunnel) streamed the desktop" || fail "web app $proto connection"
  done
}
auth_state(){
  local b; b=$(curl -s --max-time 20 -X POST http://127.0.0.1:8080/betterguac/api/tokens --data-urlencode "username=$1" --data-urlencode "password=$2")
  if echo "$b" | grep -q '"authToken"'; then echo OK
  elif echo "$b" | grep -q 'INSUFFICIENT_CREDENTIALS' && echo "$b" | grep -q 'guac-totp'; then echo TOTP
  elif echo "$b" | grep -q 'INVALID_CREDENTIALS'; then echo INVALID
  else echo "OTHER:$(echo "$b" | head -c 120)"; fi
}
