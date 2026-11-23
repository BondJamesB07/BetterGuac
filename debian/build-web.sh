#!/bin/sh
# Assembles the BetterGuac web application and extensions.
#   build-web.sh <build dir> <package version>
# Output in <build dir>/web/out: guacamole-javax.war and the extension jars.
# They are NOT converted to jakarta.* here: the web application bundles
# third-party libraries under the EPL and CDDL (Jersey, HK2, Jakarta
# Annotations, Logback, JSR-250), and the package ships them unmodified.
# betterguac-setup converts them on the installed machine with Debian's
# Apache Tomcat migration tool (javax2jakarta, package
# tomcat-jakartaee-migration), the same conversion Tomcat 10 applies to
# applications placed in its webapps-javaee folder.
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
# change notice inside the modified file (Apache License 2.0, section 4b)
python3 - "$IDX" <<'PYEOF'
import sys
idx = sys.argv[1]; h = open(idx).read()
note = ("<!-- Modified by BetterGuac, 2026: page title, early page colour, boot loader and "
        "cache stamps added to the Apache Guacamole 1.6.0 index.html. See NOTICE. -->")
assert h.count("<!doctype html>") == 1
open(idx, "w").write(h.replace("<!doctype html>", "<!doctype html>" + note, 1))
PYEOF
grep -q 'Modified by BetterGuac' "$IDX"
if [ -x "$S/patches/webapp-extra.sh" ]; then "$S/patches/webapp-extra.sh" "$W/war"; fi

# --- BetterGuac UI add-on + profile/auth extension ---
LIB=$W/war/WEB-INF/lib
javac --release 11 -nowarn -encoding UTF-8 -cp "$LIB/*" -d "$W/classes" $(find "$S/addon-java" -name '*.java')
cp -a "$S/addon" "$W/addon"
rm -rf "$W/addon/com"
cp -a "$W/classes/com" "$W/addon/com"
# the add-on jar carries its own license and notice in case it is copied on its own
mkdir -p "$W/addon/META-INF"
cp "$S/LICENSE" "$W/addon/META-INF/LICENSE"
cp "$S/files/NOTICE" "$W/addon/META-INF/NOTICE"
(cd "$W/addon" && find . -type f | LC_ALL=C sort | sed 's#^\./##' | zip -q -X -@ "$W/ext/betterguac-ui-1.6.0.jar")

# --- Database authentication (patched) and TOTP ---
tar -xzf "$S/upstream/guacamole-auth-jdbc-1.6.0.tar.gz" -C "$W"
tar -xzf "$S/upstream/guacamole-auth-totp-1.6.0.tar.gz" -C "$W"
python3 "$S/patches/0003-jdbc-mysql-patch_jar.py" \
    "$W/guacamole-auth-jdbc-1.6.0/mysql/guacamole-auth-jdbc-mysql-1.6.0.jar" \
    "$W/ext/guacamole-auth-jdbc-mysql-1.6.0.jar"
# mark the patched jar as modified in its manifest (Apache License 2.0, section 4b)
python3 - "$W/ext/guacamole-auth-jdbc-mysql-1.6.0.jar" <<'PYEOF'
import sys, zipfile, os, shutil
jar = sys.argv[1]; tmp = jar + ".tmp"
zin = zipfile.ZipFile(jar); zout = zipfile.ZipFile(tmp, "w")
seen = False
for info in zin.infolist():
    data = zin.read(info.filename)
    if info.filename == "META-INF/MANIFEST.MF":
        seen = True
        lines = [l for l in data.decode("utf-8").replace("\r\n", "\n").split("\n")
                 if l and not l.startswith("Implementation-Vendor:")]
        lines.append("Implementation-Vendor: BetterGuac (modified Apache Guacamole 1.6.0; see NOTICE)")
        data = ("\r\n".join(lines) + "\r\n\r\n").encode("utf-8")
    zout.writestr(info, data)
zout.close(); zin.close()
assert seen, "no MANIFEST.MF in the jdbc jar"
os.replace(tmp, jar)
PYEOF
cp "$W/guacamole-auth-totp-1.6.0/guacamole-auth-totp-1.6.0.jar" "$W/ext/"
mkdir -p "$W/schema"
cp "$W"/guacamole-auth-jdbc-1.6.0/mysql/schema/*.sql "$W/schema/"

# --- Shipped as javax.*: converted to jakarta.* on the installed machine ---
(cd "$W/war" && find . -type f | LC_ALL=C sort | sed 's#^\./##' | zip -q -X -@ "$W/out/guacamole-javax.war")
# newer upstream releases of bundled third-party libraries (security fixes);
# see patches/0004-refresh-bundled-libs.py and upstream/third-party/
python3 "$S/patches/0004-refresh-bundled-libs.py" "$S/upstream/third-party" \
    "$W/out/guacamole-javax.war" "$W/ext/guacamole-auth-jdbc-mysql-1.6.0.jar" \
    "$W/ext/guacamole-auth-totp-1.6.0.jar"
cp "$W"/ext/*.jar "$W/out/"
ls -l "$W/out"
