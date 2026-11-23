#!/bin/sh
# Debian/Ubuntu package and container image only (Arch has its own copies,
# see packaging/arch/PKGBUILD): installs the runtime pieces BetterGuac ships
# itself because the distributions' packages are older and miss security
# fixes. All are unmodified upstream releases, checked against
# upstream/third-party/SHA256SUMS (and Apache's .sha512 file for Tomcat).
#   install-runtime.sh <build dir> <package dir>
set -eu
B=$1; P=$2; S=$(pwd)
SH=$P/usr/share/betterguac
TP=$S/upstream/third-party
TCV=10.1.62
MJC=2.7.15
(cd "$TP" && sha256sum -c --quiet SHA256SUMS && sha512sum -c --quiet apache-tomcat-$TCV.tar.gz.sha512)

# MariaDB Connector/J (LGPL-2.1), used by the JDBC extension; the distro's
# libmariadb-java is 2.7.6, without the fixes for CVE-2026-55856/7/8 (2.7.14)
install -d -m 755 "$SH/java"
install -m 644 "$TP/mariadb-java-client-$MJC.jar" "$SH/java/mariadb-java-client-$MJC.jar"
ln -s "mariadb-java-client-$MJC.jar" "$SH/java/mariadb-java-client.jar"
install -d -m 755 "$SH/legal/mariadb-connector-j"
install -m 644 "$TP/mariadb-connector-j-$MJC-LICENSE" "$SH/legal/mariadb-connector-j/LICENSE"

# Apache Tomcat runtime: CATALINA_HOME for the tomcat10 service (the drop-in
# points it here). Only bin/ and lib/ are used; the distribution's
# /var/lib/tomcat10 and /etc/tomcat10 stay CATALINA_BASE and the
# configuration. conf-dist/ is upstream's stock configuration, used by the
# container image, which has no tomcat10 package.
TCT=$B/apache-tomcat-$TCV
rm -rf "$TCT"; tar -xzf "$TP/apache-tomcat-$TCV.tar.gz" -C "$B"
TCD=$SH/tomcat
install -d -m 755 "$TCD/bin" "$TCD/lib" "$TCD/conf-dist"
for f in bootstrap.jar tomcat-juli.jar catalina.sh setclasspath.sh version.sh digest.sh tool-wrapper.sh configtest.sh migrate.sh; do
    case $f in *.sh) m=755;; *) m=644;; esac
    install -m $m "$TCT/bin/$f" "$TCD/bin/$f"
done
# without the clustering jars (catalina-ha, catalina-tribes): BetterGuac runs
# one Tomcat and never loads them, and the unfixed cluster issues
# (CVE-2026-133325, the EncryptInterceptor) live there
for f in "$TCT"/lib/*.jar; do
    case $(basename "$f") in catalina-ha.jar|catalina-tribes.jar) continue;; esac
    install -m 644 "$f" "$TCD/lib/"
done
install -m 644 "$TCT"/conf/* "$TCD/conf-dist/"
install -m 644 "$TCT/RELEASE-NOTES" "$TCD/"
install -d -m 755 "$SH/legal/apache-tomcat"
install -m 644 "$TCT/LICENSE" "$TCT/NOTICE" "$SH/legal/apache-tomcat/"
rm -rf "$TCT"
