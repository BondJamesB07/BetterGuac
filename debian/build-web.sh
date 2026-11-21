#!/bin/sh
# Assembles the BetterGuac web application and extensions.
#   build-web.sh <build dir> <package version>
# Output in <build dir>/web/out: guacamole.war and the extension jars, all
# converted from javax.* to jakarta.* for Tomcat 10.
set -eu
B=$1; VER=$2; S=$(pwd)
W=$B/web
rm -rf "$W"; mkdir -p "$W/war" "$W/ext" "$W/out" "$W/classes"

# --- Web application: stock 1.6.0 war with BetterGuac's index.html changes ---
(cd "$W/war" && unzip -q "$S/upstream/guacamole-1.6.0.war")
IDX=$W/war/index.html
# the stamp follows the version and the UI add-on's contents, so a changed add-on is never served from cache
STAMP=$( { printf '%s\n' "betterguac-$VER"; (cd "$S/addon" && find . -type f | LC_ALL=C sort | xargs sha256sum); } | sha256sum | cut -c1-10)
# browsers behind a proxy cache app.css/app.js for hours: stamp them per release
sed -i -E "s/(app\.(css|js)\?b=[0-9]+)/\1\&bg=$STAMP/g" "$IDX"
# fixed title and midnight-blue page colour before any script runs (no APP.NAME flash)
sed -i 's#<title ng-bind="page.title | translate"></title>#<title ng-bind="page.title | translate">BetterGuac</title>#' "$IDX"
sed -i 's#<link rel="stylesheet"#<style id="bg-boot-bg">html,body{background-color:\#0c1530}</style><link rel="stylesheet"#' "$IDX"
grep -q 'bg-boot-bg' "$IDX"
# avocado from the first paint: inline in index.html, so it shows while the stylesheets and
# scripts are still downloading on a slow link (the add-on's own loader only exists once app.js has loaded)
python3 - "$IDX" "$S/debian/boot-loader.html" <<'PYEOF'
import sys
idx, snip = sys.argv[1], open(sys.argv[2]).read().strip()
h = open(idx).read()
# right after the colour block and BEFORE the stylesheet links: a script placed after a
# pending stylesheet waits for it, which on a slow link is most of the wait
mark = '<style id="bg-boot-bg">html,body{background-color:#0c1530}</style>'
assert h.count(mark) == 1 and h.index(mark) < h.index('<link rel="stylesheet"')
open(idx, "w").write(h.replace(mark, mark + snip, 1))
PYEOF
grep -q 'id="bg-boot-script"' "$IDX"
grep -q '>BetterGuac</title>' "$IDX"
grep -q "bg=$STAMP" "$IDX"
if [ -x "$S/patches/webapp-extra.sh" ]; then "$S/patches/webapp-extra.sh" "$W/war"; fi

# --- BetterGuac UI add-on + profile/auth extension ---
LIB=$W/war/WEB-INF/lib
javac --release 11 -nowarn -encoding UTF-8 -cp "$LIB/*" -d "$W/classes" $(find "$S/addon-java" -name '*.java')
cp -a "$S/addon" "$W/addon"
rm -rf "$W/addon/com"
cp -a "$W/classes/com" "$W/addon/com"
(cd "$W/addon" && find . -type f | LC_ALL=C sort | sed 's#^\./##' | zip -q -X -@ "$W/ext/betterguac-ui-1.6.0.jar")

# --- Database authentication (patched) and TOTP ---
tar -xzf "$S/upstream/guacamole-auth-jdbc-1.6.0.tar.gz" -C "$W"
tar -xzf "$S/upstream/guacamole-auth-totp-1.6.0.tar.gz" -C "$W"
python3 "$S/patches/0003-jdbc-mysql-patch_jar.py" \
    "$W/guacamole-auth-jdbc-1.6.0/mysql/guacamole-auth-jdbc-mysql-1.6.0.jar" \
    "$W/ext/guacamole-auth-jdbc-mysql-1.6.0.jar"
cp "$W/guacamole-auth-totp-1.6.0/guacamole-auth-totp-1.6.0.jar" "$W/ext/"
mkdir -p "$W/schema"
cp "$W"/guacamole-auth-jdbc-1.6.0/mysql/schema/*.sql "$W/schema/"

# --- javax -> jakarta for Tomcat 10 (same conversion Tomcat's webapps-javaee does) ---
(cd "$W/war" && find . -type f | LC_ALL=C sort | sed 's#^\./##' | zip -q -X -@ "$W/guacamole-javax.war")
javax2jakarta -profile=TOMCAT "$W/guacamole-javax.war" "$W/out/guacamole.war"
for j in "$W"/ext/*.jar; do
    javax2jakarta -profile=TOMCAT "$j" "$W/out/$(basename "$j")"
done
ls -l "$W/out"
