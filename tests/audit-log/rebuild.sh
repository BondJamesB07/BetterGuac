#!/bin/bash
# Rebuild the extension jar from the branch worktree and the test image.
set -e
cd ~/bgaudit-test
docker run --rm -v ~/BetterGuac/wt-audit-log:/src:ro -v ~/bgaudit-test/out:/out debian:trixie bash -c '
set -e; export DEBIAN_FRONTEND=noninteractive
apt-get update -qq; apt-get install -y -qq --no-install-recommends default-jdk-headless tomcat-jakartaee-migration zip unzip >/dev/null
W=/tmp/w; mkdir -p $W/war $W/classes $W/ext; cd $W/war; unzip -q /src/upstream/guacamole-1.6.0.war
cd /src; javac --release 11 -nowarn -encoding UTF-8 -cp "$W/war/WEB-INF/lib/*" -d $W/classes $(find addon-java -name "*.java")
cp -a addon $W/addon; rm -rf $W/addon/com; cp -a $W/classes/com $W/addon/com
(cd $W/addon && find . -type f | LC_ALL=C sort | sed "s#^\./##" | zip -q -X -@ $W/ext/betterguac-ui-1.6.0.jar)
rm -f /out/betterguac-ui-1.6.0.jar
javax2jakarta -profile=TOMCAT $W/ext/betterguac-ui-1.6.0.jar /out/betterguac-ui-1.6.0.jar >/dev/null 2>&1
ls -la /out/betterguac-ui-1.6.0.jar'
rm -rf wt && mkdir -p wt && (cd ~/BetterGuac/wt-audit-log && git archive HEAD files yaml-sync schema) | tar -xf - -C wt
mkdir -p wt/docker/docker && cp ~/BetterGuac/wt-audit-log/docker/docker/entrypoint.sh wt/docker/docker/
docker build -q -t betterguac:audit-log-test -f Dockerfile.audit . >/dev/null && echo "image rebuilt"
