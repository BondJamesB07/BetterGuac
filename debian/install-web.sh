#!/bin/sh
# Installs the web application, extensions, setup scripts and config into
# the package tree.   install-web.sh <build dir> <package dir>
set -eu
B=$1; P=$2; S=$(pwd); W=$B/web
SH=$P/usr/share/betterguac
# The web application and extensions are shipped as built (javax.*), with
# some bundled third-party libraries swapped for newer upstream releases by
# build-web.sh (patches/0004-refresh-bundled-libs.py). betterguac-setup converts them for
# Tomcat 10 into /var/cache/betterguac on the installed machine.
mkdir -p "$SH/javaee/extensions" "$SH/schema" "$SH/templates"
install -m 644 "$W/out/guacamole-javax.war" "$SH/javaee/guacamole.war"
for j in "$W"/out/*.jar; do install -m 644 "$j" "$SH/javaee/extensions/"; done
install -m 644 "$W"/schema/*.sql "$SH/schema/"
# BetterGuac's own numbered schema changes (betterguac-admin migrate)
mkdir -p "$SH/schema/betterguac"
install -m 644 schema/betterguac/*.sql "$SH/schema/betterguac/"
install -m 644 files/guacamole.properties.in files/context.xml.in files/redirect-context.xml.in "$SH/templates/"
mkdir -p "$SH/redirect/WEB-INF"
install -m 644 files/redirect-web.xml "$SH/redirect/WEB-INF/web.xml"
install -m 644 files/redirect.jsp "$SH/redirect/redirect.jsp"
install -m 644 files/betterguac.yaml.example files/betterguac.yaml.starter "$SH/"

# setup helper and YAML sync tool
mkdir -p "$P/usr/lib/betterguac/sync" "$P/usr/sbin"
install -m 755 files/betterguac-setup "$P/usr/lib/betterguac/betterguac-setup"
install -m 755 yaml-sync/betterguac_sync.py "$P/usr/lib/betterguac/sync/betterguac_sync.py"
install -m 644 yaml-sync/state-schema.sql "$P/usr/lib/betterguac/sync/state-schema.sql"
install -m 755 files/betterguac-sync "$P/usr/sbin/betterguac-sync"
install -m 755 files/betterguac-admin "$P/usr/sbin/betterguac-admin"
mkdir -p "$P/usr/share/man/man8"
for m in betterguac-sync betterguac-admin; do
    gzip -9n -c files/$m.8 > "$P/usr/share/man/man8/$m.8.gz"
done

# config folder (GUACAMOLE_HOME): guacd.conf is a conffile; the extensions
# and the JDBC driver are links to the packaged files.
mkdir -p "$P/etc/betterguac/extensions" "$P/etc/betterguac/lib"
install -m 644 files/guacd.conf "$P/etc/betterguac/guacd.conf"
for j in "$SH"/javaee/extensions/*.jar; do
    ln -s "/var/cache/betterguac/extensions/$(basename "$j")" "$P/etc/betterguac/extensions/$(basename "$j")"
done
ln -s /usr/share/betterguac/java/mariadb-java-client.jar "$P/etc/betterguac/lib/mariadb-java-client.jar"

# Tomcat 10 drop-in: GUACAMOLE_HOME
mkdir -p "$P/usr/lib/systemd/system/tomcat10.service.d"
install -m 644 files/tomcat10-betterguac.conf "$P/usr/lib/systemd/system/tomcat10.service.d/betterguac.conf"

# docs
mkdir -p "$P/usr/share/doc/betterguac"
install -m 644 README.md "$P/usr/share/doc/betterguac/README.md"
install -m 644 files/NOTICE "$P/usr/share/doc/betterguac/NOTICE"
install -m 644 "$B/guacamole-server-1.6.0/LICENSE" "$P/usr/share/doc/betterguac/LICENSE"
install -m 644 files/README.Debian "$P/usr/share/doc/betterguac/README.Debian"
install -m 644 files/SOURCES "$P/usr/share/doc/betterguac/SOURCES"
# Also outside /usr/share/doc: minimal Ubuntu and Debian images drop
# /usr/share/doc (all but copyright) at install time, and these must stay.
mkdir -p "$P/usr/share/betterguac/legal"
install -m 644 files/NOTICE "$P/usr/share/betterguac/legal/NOTICE"
install -m 644 files/SOURCES "$P/usr/share/betterguac/legal/SOURCES"
install -m 644 LICENSE "$P/usr/share/betterguac/legal/LICENSE"

# credits of the two upstream extensions: each release archive has its own
# LICENSE, NOTICE and bundled/ (third-party licenses of the libraries inside
# its jar). Kept in one folder per extension so nothing overwrites the main
# LICENSE/NOTICE or the other extension's files.
for x in guacamole-auth-jdbc guacamole-auth-totp; do
    X=$W/$x-1.6.0; D=$P/usr/share/doc/betterguac/$x
    test -d "$X/bundled"
    install -d -m 755 "$D"
    install -m 644 "$X/LICENSE" "$X/NOTICE" "$D/"
    cp -R "$X/bundled" "$D/bundled"
    find "$D/bundled" -type d -exec chmod 755 {} +
    find "$D/bundled" -type f -exec chmod 644 {} +
    # and outside /usr/share/doc, which minimal images drop
    cp -R "$D" "$P/usr/share/betterguac/legal/$x"
done
