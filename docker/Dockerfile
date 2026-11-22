# BetterGuac 1.6.0-bg11 image (package 1.6.0+bg11) template — native arm64 and amd64 (single container)
#
# No per-machine edits: the architecture is detected at build time from
# Docker's TARGETARCH and the matching .deb is taken from
# debs/betterguac_<version>_<arch>.deb.
#
# The .deb is deliberately NOT shipped here. Put the package for the machine
# you build on in ./debs/ first, e.g.
#   debs/betterguac_1.6.0+bg11_arm64.deb   (arm64 / bondlab)
#   debs/betterguac_1.6.0+bg11_amd64.deb   (amd64 / proxlab1)
# See README.md ("Put the .deb in debs/").
FROM debian:trixie-slim

ARG VCS_REF=unknown
LABEL org.opencontainers.image.title="BetterGuac" \
      org.opencontainers.image.version="1.6.0-bg11" \
      org.opencontainers.image.description="BetterGuac remote access (based on Apache Guacamole 1.6.0), single container" \
      org.opencontainers.image.licenses="Apache-2.0" \
      io.betterguac.sbom="/usr/share/betterguac/legal/sbom (Debian packages and their licenses; source notice in /usr/share/betterguac/legal/SOURCES)" \
      org.opencontainers.image.source="https://github.com/BondJamesB07/BetterGuac" \
      io.betterguac.package-version="1.6.0+bg11" \
      org.opencontainers.image.revision="${VCS_REF}"

ARG DEBIAN_FRONTEND=noninteractive

# betterguac version (used to pick the .deb).
# TARGETARCH is set automatically by Docker Compose/BuildKit for the host
# platform (amd64/arm64). A plain `docker build` outside Compose also sets it
# through BuildKit's default platform. If it were ever empty, the COPY below
# fails with a clear message; there is no silent cross-architecture build.
ARG TARGETARCH
ARG BETTERGUAC_VERSION=1.6.0+bg11

# Build-time package workaround (see README.md "Package postinst workaround"):
#  - policy-rc.d blocks invoke-rc.d, so no service is started at install time
#  - the package's dependencies are installed first, then the .deb is unpacked
#    with dpkg -i --force-depends. Its postinst fails because it cannot start
#    MariaDB without systemd; the package is left half-configured.
#  - MariaDB is then started by hand and the package's own maintainer script
#    (dpkg --configure betterguac -> betterguac-setup) is run once, with an
#    EMPTY admin password, so it generates the admin password and prints only
#    "the administrator's password is in /etc/betterguac/initial-admin.txt".
#  - the per-run secrets and the first-admin file are then deleted and
#    regenerated on the first container boot, so no dummy password is ever
#    baked into an image layer.
#
# Everything the package's setup does at run time is driven by its own scripts
# (betterguac-setup, betterguac_sync.py); this Dockerfile only makes the image
# able to install the package without systemd and removes build-time secrets.
#
# The architecture is taken from TARGETARCH, which Docker Compose sets for the
# host platform (amd64/arm64). No per-machine edits are needed; building for
# the other architecture on this host would need emulation and is out of scope.

COPY debs/betterguac_${BETTERGUAC_VERSION}_${TARGETARCH}.deb /tmp/betterguac.deb
# Release checksums: the build stops if the .deb does not match its published SHA-256.
COPY debs/SHA256SUMS /tmp/betterguac.SHA256SUMS

RUN set -eux; \
    expected=$(awk -v f="betterguac_${BETTERGUAC_VERSION}_${TARGETARCH}.deb" '$2==f{print $1}' /tmp/betterguac.SHA256SUMS); \
    test -n "$expected"; \
    echo "$expected  /tmp/betterguac.deb" | sha256sum -c -; \
    rm -f /tmp/betterguac.SHA256SUMS; \
    # debian:*-slim drops /usr/share/doc/* except copyright. Keep BetterGuac's
    # own LICENSE/NOTICE and the add-on credit files the package ships there.
    printf 'path-include /usr/share/doc/betterguac/*\npath-include /usr/share/man/man8/betterguac-*\npath-include /usr/share/lintian/overrides/betterguac\n' > /etc/dpkg/dpkg.cfg.d/zz-betterguac-docs; \
    printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d; \
    chmod 0755 /usr/sbin/policy-rc.d; \
    # fixed user and group IDs, the same as the bg10 image, so existing
    # volumes (owned by tomcat 997:997 and mysql 100:101) keep working
    groupadd --system --gid 101 mysql; \
    useradd --system --uid 100 --gid 101 --home-dir /nonexistent --shell /bin/false --comment "MariaDB Server" mysql; \
    groupadd --system --gid 997 tomcat; \
    useradd --system --uid 997 --gid 997 --home-dir /var/lib/tomcat --shell /usr/sbin/nologin --comment "Apache Tomcat" tomcat; \
    # FreeRDP 3.33.1 from trixie-backports at run time (guacd is built
    # against trixie's FreeRDP 3; same library names and ABI)
    printf 'Types: deb\nURIs: http://deb.debian.org/debian\nSuites: trixie-backports\nComponents: main\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg\n' > /etc/apt/sources.list.d/backports.sources; \
    apt-get update; \
    apt-get upgrade -y; \
    apt-get install -y --no-install-recommends \
        ca-certificates supervisor tini iproute2 procps curl \
        mariadb-client mariadb-server \
        libcairo2 libglib2.0-0t64 \
        libjpeg62-turbo libpango-1.0-0 libpangocairo-1.0-0 libpng16-16t64 \
        libpulse0 libssh2-1t64 libssl3t64 libtelnet2 libuuid1 \
        libvncclient1 libwebp7 libwebsockets19t64 \
        fonts-dejavu-core python3-pymysql python3-yaml default-jre-headless; \
    apt-get install -y --no-install-recommends -t trixie-backports \
        libfreerdp-client3-3 libfreerdp3-3 libwinpr3-3; \
    test "$(getent passwd tomcat | cut -d: -f3,4)" = 997:997; \
    test "$(getent passwd mysql | cut -d: -f3,4)" = 100:101; \
    mkdir -p /etc/betterguac/extensions /etc/betterguac/lib /var/lib/betterguac; \
    # Unpack + postinst. The postinst is expected to fail (no MariaDB yet).
    dpkg -i --force-depends /tmp/betterguac.deb \
        || echo "dpkg -i reported the expected postinst failure (no MariaDB at install time)"; \
    rm -f /tmp/betterguac.deb; \
    # No tomcat10 package in the image: the web application runs on the
    # Apache Tomcat 10.1.62 release the package ships. Lay out a Tomcat
    # base like Debian's (/var/lib/tomcat10, conf -> /etc/tomcat10) from
    # Tomcat's stock configuration, with the shutdown port off as Debian has it.
    install -d -m 0755 -o root -g tomcat /etc/tomcat10; \
    install -d -m 0775 -o root -g tomcat /etc/tomcat10/Catalina /etc/tomcat10/Catalina/localhost; \
    install -m 0640 -o root -g tomcat /usr/share/betterguac/tomcat/conf-dist/* /etc/tomcat10/; \
    sed -i 's#<Server port="8005" shutdown="SHUTDOWN">#<Server port="-1" shutdown="SHUTDOWN">#' /etc/tomcat10/server.xml; \
    grep -q '<Server port="-1"' /etc/tomcat10/server.xml; \
    install -d -m 0755 /var/lib/tomcat10; \
    install -d -m 0775 -o tomcat -g tomcat /var/lib/tomcat10/webapps; \
    install -d -m 0755 -o tomcat -g tomcat /var/lib/tomcat10/lib /var/lib/tomcat /var/cache/tomcat10; \
    install -d -m 2750 -o tomcat -g adm /var/log/tomcat10; \
    ln -s /etc/tomcat10 /var/lib/tomcat10/conf; \
    ln -s ../../log/tomcat10 /var/lib/tomcat10/logs; \
    ln -s ../../cache/tomcat10 /var/lib/tomcat10/work; \
    # The .deb ships symlinks inside /etc/betterguac/{extensions,lib}.
    # /etc/betterguac is replaced by an empty Docker volume at run time, so
    # re-create the same links now: the first-run init script copies them into
    # the volume. The FreeRDP plugin folder is named for the processor type
    # (e.g. /usr/lib/aarch64-linux-gnu/freerdp3 on arm64,
    # /usr/lib/x86_64-linux-gnu/freerdp3 on amd64); the freerdp libraries
    # there are found through the default multiarch loader path, so nothing
    # in the scripts hardcodes the processor name.
    for jar in /usr/share/betterguac/javaee/extensions/*.jar; do \
        ln -sfn "/var/cache/betterguac/extensions/$(basename "$jar")" "/etc/betterguac/extensions/$(basename "$jar")"; \
    done; \
    ln -sfn /usr/share/betterguac/java/mariadb-java-client.jar /etc/betterguac/lib/mariadb-java-client.jar; \
    # Start MariaDB for the duration of the build and finish the package setup.
    mariadbd-safe --skip-syslog >/tmp/mariadb-build.log 2>&1 & \
    for i in $(seq 1 90); do \
        mariadb --protocol=socket -uroot -e 'SELECT 1' >/dev/null 2>&1 && break; \
        sleep 1; \
    done; \
    mariadb --protocol=socket -uroot -e 'SELECT 1'; \
    # tomcat10 is the package's only dependency the image leaves out (see
    # above); everything else is installed
    dpkg --force-depends --configure betterguac; \
    dpkg -s betterguac | grep -q '^Status: install ok installed'; \
    # record that in dpkg's database, so apt in the container doesn't try
    # to "fix" the missing tomcat10 by installing the old one
    sed -i '/^Package: betterguac$/,/^$/ s/^\(Depends: .*\), tomcat10\(,\|$\)/\1\2/' /var/lib/dpkg/status; \
    ! dpkg -s betterguac | grep '^Depends:' | grep -qw tomcat10; \
    apt-get check; \
    mariadb-admin shutdown; \
    for i in $(seq 1 40); do pgrep -x mariadbd >/dev/null || break; sleep 1; done; \
    test "$(pgrep -x mariadbd | wc -l)" = 0; \
    # Remove every build-time secret. They are regenerated on first boot.
    rm -f /etc/betterguac/guacamole.properties /etc/betterguac/sync.env \
          /etc/betterguac/betterguac.yaml /etc/betterguac/initial-admin.txt \
          /var/lib/betterguac/admin-user; \
    rm -rf /var/lib/mysql; \
    # The web application is converted to jakarta.* when the container starts
    # (betterguac-tomcat-run), not baked into the image: the image ships the
    # Apache Guacamole WAR and its third-party libraries unmodified.
    rm -rf /var/cache/betterguac; \
    # the build-time setup run leaves the migration lock and backup folder in
    # the state directory; first boot must find it empty
    rm -rf /var/lib/betterguac/backups /var/lib/betterguac/migrate.lock; \
    test -z "$(ls -A /var/lib/betterguac)"; \
    rm -rf /var/lib/apt/lists/* /tmp/mariadb-build.log; \
    # make sure nothing from the build run can be mistaken for runtime state
    test ! -e /etc/betterguac/guacamole.properties

# SBOM: every Debian package in the image, with version and source package,
# as a table and as SPDX 2.3, plus where to get the source (SOURCES).
COPY docker/make-sbom.py /usr/local/lib/betterguac-make-sbom.py
RUN set -eux; \
    install -d -m 0755 /usr/share/betterguac/legal/sbom; \
    python3 /usr/local/lib/betterguac-make-sbom.py /usr/share/betterguac/legal/sbom; \
    rm -f /usr/local/lib/betterguac-make-sbom.py; \
    test -s /usr/share/betterguac/legal/sbom/packages.tsv; \
    test -s /usr/share/betterguac/legal/sbom/betterguac.spdx.json; \
    test -s /usr/share/betterguac/legal/SOURCES

COPY docker/supervisord.conf /etc/supervisor/conf.d/betterguac.conf
COPY docker/entrypoint.sh /usr/local/bin/betterguac-entrypoint
COPY docker/wait-for-db.sh /usr/local/bin/betterguac-wait-for-db
COPY docker/healthcheck.sh /usr/local/bin/betterguac-healthcheck
COPY docker/guacd-run.sh /usr/local/bin/betterguac-guacd-run
COPY docker/tomcat-run.sh /usr/local/bin/betterguac-tomcat-run
COPY docker/mariadb-run.sh /usr/local/bin/betterguac-mariadb-run
# healthcheck.sh uses a bash [[ ]] test, so the shebang is /bin/bash
RUN chmod 0755 /usr/local/bin/betterguac-entrypoint /usr/local/bin/betterguac-wait-for-db \
        /usr/local/bin/betterguac-healthcheck /usr/local/bin/betterguac-guacd-run \
        /usr/local/bin/betterguac-tomcat-run /usr/local/bin/betterguac-mariadb-run

EXPOSE 8080
STOPSIGNAL SIGQUIT

ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/betterguac-entrypoint"]