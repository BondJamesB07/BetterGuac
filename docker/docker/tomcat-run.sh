#!/bin/bash
# Run Tomcat 10 in the foreground as the tomcat user, with exactly the
# environment the package's tomcat10 drop-in and Debian's tomcat10 service use:
#   CATALINA_HOME / CATALINA_BASE / CATALINA_TMPDIR
#   GUACAMOLE_HOME=/etc/betterguac   (from betterguac's drop-in)
#   JAVA_HOME, CATALINA_OPTS         (from /etc/default/tomcat10)
set -euo pipefail
# shellcheck disable=SC1091
[ -r /etc/default/tomcat10 ] && . /etc/default/tomcat10
export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/default-java}"
export CATALINA_HOME=/usr/share/tomcat10
export CATALINA_BASE=/var/lib/tomcat10
export CATALINA_TMPDIR=/tmp
export GUACAMOLE_HOME=/etc/betterguac
# keep all Tomcat logging on the container's stdout/stderr
export CATALINA_OUT=/dev/stdout
export CATALINA_OUT_CMD=
# convert the shipped web application for Tomcat 10 (javax to jakarta) on
# first start; later starts reuse it unless the package changed
/usr/lib/betterguac/betterguac-setup webapp
exec runuser -u tomcat -- "$CATALINA_HOME/bin/catalina.sh" run