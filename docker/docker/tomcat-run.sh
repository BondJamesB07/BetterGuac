#!/bin/bash
# Run Tomcat 10 in the foreground as the tomcat user, with the same layout
# the package uses on Debian/Ubuntu:
#   CATALINA_HOME=/usr/share/betterguac/tomcat  (the Apache Tomcat 10.1.62
#                                               release the package ships)
#   CATALINA_BASE=/var/lib/tomcat10             (conf -> /etc/tomcat10)
#   GUACAMOLE_HOME=/etc/betterguac              (from betterguac's drop-in)
#   JAVA_HOME, JAVA_OPTS, CATALINA_OPTS         (/etc/default/tomcat10 if present)
set -euo pipefail
# shellcheck disable=SC1091
[ -r /etc/default/tomcat10 ] && . /etc/default/tomcat10
export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/default-java}"
export JAVA_OPTS="${JAVA_OPTS:--Djava.awt.headless=true}"
export CATALINA_HOME=/usr/share/betterguac/tomcat
export CATALINA_BASE=/var/lib/tomcat10
export CATALINA_TMPDIR=/tmp
export GUACAMOLE_HOME=/etc/betterguac
# keep all Tomcat logging on the container's stdout/stderr
export CATALINA_OUT=/dev/stdout
export CATALINA_OUT_CMD=
# convert the shipped web application for Tomcat 10 (javax to jakarta) on
# first start; later starts reuse it unless the package changed. This also
# moves an old JDBC driver link in the settings volume to the bundled
# Connector/J.
/usr/lib/betterguac/betterguac-setup webapp
cd "$CATALINA_BASE"
exec runuser -u tomcat -- "$CATALINA_HOME/bin/catalina.sh" run
