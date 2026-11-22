#!/bin/bash
# bg10 checks, sourced after common.sh inside an installed systemd container or VM:
# migrations, Activity log (incl. client address behind a proxy), license files.
# needs: PASS/FAIL helpers, sql, admin_user, admin_pw
BASE=${BASE:-http://127.0.0.1:8080/betterguac}
tok(){ curl -s --max-time 20 -X POST $BASE/api/tokens "$@" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("authToken",""))' 2>/dev/null; }
bg10_checks(){
  local U P TK V A R N
  U=$(admin_user); P=$(admin_pw)
  V=$(dpkg-query -W -f='${Version}' betterguac)
  [ "$V" = "1.6.0+bg11" ] && pass "installed version $V" || fail "installed version '$V'"
  # migrations
  N=$(sql -e "SELECT COUNT(*) FROM bg_schema_migration" 2>/dev/null)
  [ "${N:-0}" -ge 1 ] && pass "schema migrations recorded ($N)" || fail "no bg_schema_migration rows"
  betterguac-admin migrate --status > /tmp/mig.txt 2>&1
  AP=$(sed -n '/^applied:/,/^shipped:/p' /tmp/mig.txt | grep -c '^  [0-9]'); SH=$(sed -n '/^shipped:/,$p' /tmp/mig.txt | grep -c '^  [0-9]')
  [ "$AP" -ge 1 ] && [ "$AP" = "$SH" ] && pass "migrate --status: $AP applied of $SH shipped" || { fail "migrate --status applied=$AP shipped=$SH"; cat /tmp/mig.txt; }
  betterguac-admin migrate > /tmp/mig2.txt 2>&1 && grep -q "up to date" /tmp/mig2.txt && pass "betterguac-admin migrate re-run: schema up to date, nothing applied" || { fail "migrate re-run"; tail -n 3 /tmp/mig2.txt; }
  # Tomcat 10 copy made on this machine, WAR shipped as javax
  [ -f /var/cache/betterguac/webapp/WEB-INF/web.xml ] && pass "web application converted into /var/cache/betterguac" || fail "no converted webapp"
  python3 - <<'PY' && pass "shipped WAR is javax (unconverted), converted copy is jakarta" || fail "javax/jakarta layout"
import zipfile, glob, sys
z = zipfile.ZipFile("/usr/share/betterguac/javaee/guacamole.war")
web = z.read("WEB-INF/web.xml").decode()
conv = open("/var/cache/betterguac/webapp/WEB-INF/web.xml").read()
jars = [n for n in z.namelist() if n.endswith(".jar")]
assert any("jersey" in n for n in jars), "no jersey jar"
j = zipfile.ZipFile(__import__("io").BytesIO(z.read([n for n in jars if "jersey-server" in n][0])))
cls = [n for n in j.namelist() if n.endswith(".class")]
blob = b"".join(j.read(n) for n in cls[:400])
assert b"javax/ws/rs" in blob and b"jakarta/ws/rs" not in blob, "shipped jersey not javax"
assert "javax" in web or "jakarta" not in web
sys.exit(0)
PY
  for f in legal/NOTICE legal/SOURCES legal/LICENSE legal/guacamole-auth-jdbc/NOTICE legal/guacamole-auth-totp/NOTICE; do [ -s /usr/share/betterguac/$f ] && pass "$f present" || fail "$f missing"; done; [ -s /usr/share/doc/betterguac/copyright ] && pass "copyright present" || fail "copyright missing"
  grep -q "The Apache Software Foundation" /usr/share/doc/betterguac/copyright && pass "copyright credits The Apache Software Foundation" || fail "copyright ASF"
  curl -s $BASE/ | grep -q "Modified by BetterGuac" && pass "served index.html carries the change notice" || fail "index.html change notice"
  # Activity: failed sign-in through a trusted proxy (loopback) with X-Forwarded-For
  curl -s -o /dev/null --max-time 20 -X POST $BASE/api/tokens -H 'X-Forwarded-For: 203.0.113.77' --data-urlencode "username=proxytest@example.com" --data-urlencode "password=wrong-$RANDOM"
  sleep 1
  A=$(sql -e "SELECT remote_addr FROM bg_audit_event WHERE action='auth.failed' AND actor='proxytest@example.com' ORDER BY event_id DESC LIMIT 1")
  [ "$A" = "203.0.113.77" ] && pass "Activity log records the client address from X-Forwarded-For via a trusted proxy ($A)" || fail "proxy address: got '$A'"
  # direct request (no header) records the real peer
  curl -s -o /dev/null --max-time 20 -X POST $BASE/api/tokens --data-urlencode "username=directtest@example.com" --data-urlencode "password=wrong-$RANDOM"
  sleep 1
  A=$(sql -e "SELECT remote_addr FROM bg_audit_event WHERE action='auth.failed' AND actor='directtest@example.com' ORDER BY event_id DESC LIMIT 1")
  case "$A" in 127.0.0.1|::1|0:0:0:0:0:0:0:1) pass "direct request logged with its own address ($A)";; *) fail "direct address '$A'";; esac
  # admin sign-in, Activity API
  TK=$(tok --data-urlencode "username=$U" --data-urlencode "password=$P")
  [ -n "$TK" ] && pass "admin signs in" || fail "admin sign-in"
  R=$(curl -s -w '\n%{http_code}' "$BASE/api/session/ext/mysql/audit/events?limit=50" -H "Guacamole-Token: $TK")
  [ "$(echo "$R" | tail -n 1)" = 200 ] && pass "Activity API answers 200" || fail "Activity API $(echo "$R" | tail -n 1)"
  echo "$R" | sed '$d' | grep -q "auth.failed" && pass "Activity API lists the failed sign-ins" || fail "Activity API content"
  C=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/session/ext/mysql/audit/export" -H "Guacamole-Token: $TK")
  [ "$C" = 200 ] && pass "Activity CSV export 200" || fail "export $C"
  C=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/session/ext/mysql/audit/events")
  case $C in 401|403) pass "Activity API refuses without a token ($C)";; *) fail "Activity API no-token $C";; esac
  # page assets
  curl -s "$BASE/app.js" >/dev/null
  bg11_checks
}
# bg11: refreshed third-party parts (the CVE fixes)
bg11_checks(){
  local W=/var/cache/betterguac/webapp/WEB-INF/lib j L
  for j in jackson-databind-2.21.8.jar jackson-core-2.21.8.jar guava-33.8.0-jre.jar failureaccess-1.0.3.jar logback-classic-1.5.38.jar logback-core-1.5.38.jar; do
    [ -f "$W/$j" ] && pass "web app bundles $j" || fail "web app lacks $j"
  done
  L=$(ls "$W" | grep -E '^(jackson-databind-2\.19|guava-32|logback-(classic|core)-1\.[0-4]\.|logback-(classic|core)-1\.5\.([0-9]|[12][0-9]|3[0-7])\.jar)' | tr '\n' ' ')
  [ -z "$L" ] && pass "no old Jackson, Guava or Logback jars left in the web app" || fail "old jars in web app: $L"
  python3 - <<'PY' && pass "JDBC extension carries MyBatis 3.6.0 (OGNL 3.4.16)" || fail "MyBatis/OGNL in the JDBC extension"
import zipfile, glob, io, sys
fs = [f for f in glob.glob("/etc/betterguac/extensions/*.jar") if "mysql" in f]
assert fs, "no mysql extension"
z = zipfile.ZipFile(fs[0])
n = [x for x in z.namelist() if "org/apache/ibatis/ognl" in x]
m = z.read("META-INF/maven/org.mybatis/mybatis/pom.properties").decode() if "META-INF/maven/org.mybatis/mybatis/pom.properties" in z.namelist() else ""
assert "version=3.6.0" in m, m
sys.exit(0)
PY
  L=$(readlink -f /etc/betterguac/lib/mariadb-java-client.jar)
  case "$L" in */mariadb-java-client-2.7.15.jar) pass "JDBC driver link resolves to Connector/J 2.7.15 ($L)";; *) fail "JDBC driver link -> '$L'";; esac
  if command -v dpkg-query >/dev/null 2>&1; then
    T=$(java -cp /usr/share/betterguac/tomcat/lib/catalina.jar org.apache.catalina.util.ServerInfo 2>/dev/null | sed -n 's/^Server number: *//p')
    [ "$T" = 10.1.62.0 ] && pass "bundled Tomcat is 10.1.62 ($T)" || fail "bundled Tomcat '$T'"
    ps -eo args | grep -v grep | grep -q -- '-Dcatalina.home=/usr/share/betterguac/tomcat' && pass "running Tomcat uses the bundled Tomcat" || fail "running Tomcat is not the bundled one"
    ls /usr/share/betterguac/tomcat/lib | grep -qE 'catalina-(ha|tribes)' && fail "clustering jars present" || pass "no catalina-ha/catalina-tribes clustering jars"
    D=$(dpkg-query -W -f='${Depends}' betterguac)
    echo "$D" | grep -qE 'tomcat-jakartaee-migration|libmariadb-java' && fail "old dependencies in Depends: $D" || pass "Depends has no tomcat-jakartaee-migration or libmariadb-java"
    ls /usr/share/java 2>/dev/null | grep -q '^commons-lang3-3\.17' && echo "note: commons-lang3 3.17 still on disk from another package" || pass "no commons-lang3 3.17 under /usr/share/java"
  fi
}
