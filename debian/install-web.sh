#!/bin/sh
# Installs the web application, extensions, setup scripts and config into
# the package tree.   install-web.sh <build dir> <package dir>
set -eu
B=$1; P=$2; S=$(pwd); W=$B/web
SH=$P/usr/share/betterguac
mkdir -p "$SH/webapp" "$SH/extensions" "$SH/schema" "$SH/templates"
(cd "$SH/webapp" && unzip -q "$W/out/guacamole.war")
rm -rf "$SH/webapp/META-INF/maven"
find "$SH/webapp" -type d -exec chmod 755 {} +
find "$SH/webapp" -type f -exec chmod 644 {} +
for j in "$W"/out/*.jar; do install -m 644 "$j" "$SH/extensions/"; done
install -m 644 "$W"/schema/*.sql "$SH/schema/"
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
for j in "$SH"/extensions/*.jar; do
    ln -s "/usr/share/betterguac/extensions/$(basename "$j")" "$P/etc/betterguac/extensions/$(basename "$j")"
done
ln -s /usr/share/java/mariadb-java-client.jar "$P/etc/betterguac/lib/mariadb-java-client.jar"

# Tomcat 10 drop-in: GUACAMOLE_HOME
mkdir -p "$P/usr/lib/systemd/system/tomcat10.service.d"
install -m 644 files/tomcat10-betterguac.conf "$P/usr/lib/systemd/system/tomcat10.service.d/betterguac.conf"

# docs
mkdir -p "$P/usr/share/doc/betterguac"
install -m 644 README.md "$P/usr/share/doc/betterguac/README.md"
install -m 644 files/NOTICE "$P/usr/share/doc/betterguac/NOTICE"
install -m 644 "$B/guacamole-server-1.6.0/LICENSE" "$P/usr/share/doc/betterguac/LICENSE"
install -m 644 files/README.Debian "$P/usr/share/doc/betterguac/README.Debian"
