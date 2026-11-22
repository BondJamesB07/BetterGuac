# BetterGuac 1.6.0+bg6 in Docker (arm64, single container)

A reproducible single-container image of the BetterGuac 1.6.0+bg6 Debian
package (Guacamole-based remote access gateway) for Debian trixie arm64.
MariaDB, guacd and Tomcat 10 all run in **one** container, supervised by
`supervisord` under `tini`, with first-run initialization done by the
package's own scripts.

- Compose project: `bgdocker`
- Image: `betterguac:1.6.0-bg6-arm64`
- Web UI (host): <http://127.0.0.1:18080/betterguac/> (root `/` redirects there)
- Published ports: **only** `127.0.0.1:18080 -> 8080`. 4822 and 3306 are not
  published; the package hardcodes MariaDB at 127.0.0.1:3306 and guacd at
  127.0.0.1:4822, so this is a single-container design by construction.

## Layout

```
Dockerfile                       image recipe + package-install workaround
compose.yaml                     project bgdocker, named bgdocker_* volumes, healthcheck
betterguac_1.6.0+bg6_arm64.deb   the native arm64 package (sha256 verified at build)
docker/
  entrypoint.sh                  first-run init / skip-on-marker / half-init detection
  supervisord.conf               supervisord programs: mariadb, guacd, tomcat
  mariadb-run.sh                 mariadbd in the foreground as mysql
  guacd-run.sh                   guacd -f -c /etc/betterguac/guacd.conf (root, HOME=/var/lib/betterguac-guacd)
  tomcat-run.sh                  catalina.sh run as tomcat with GUACAMOLE_HOME=/etc/betterguac
  wait-for-db.sh                 blocks until mariadb answers on its socket, then execs the real process
  healthcheck.sh                 web 200 + guacd 4822 + mariadb ping
tests/run-tests.sh               the verification suite (build, boot, crash, stop/start, recreate)
suggested-package-patches/       proposals for the next .deb (NOT applied)
test-results/                    logs and results from the suite run
```

## Build

```sh
cd ~/betterguac-docker
docker compose build
docker image inspect -f '{{.Id}} {{.Architecture}}' betterguac:1.6.0-bg6-arm64
```

The .deb is copied into the project once from `~/betterguac-arm64/out/`; the
build itself does not verify it. Verify it before rebuilding if the source is
replaced:

```sh
sha256sum betterguac_1.6.0+bg6_arm64.deb
# fd2e695665077f1d320702d21551dd1c790f5ef3a89b52405e46bbf87940187a
```

## Run

```sh
cd ~/betterguac-docker
docker compose up -d
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18080/betterguac/   # 200
docker compose exec betterguac supervisorctl status
```

First boot takes ~1–2 minutes on a 4-core arm box: the entrypoint initializes
the MariaDB datadir, runs the package's `betterguac-setup configure` once,
shuts the temporary MariaDB down cleanly, writes the marker and starts
supervisord. Subsequent boots skip init.

### The first administrator

The package generates a random password and writes it, root-only, to:

```
/etc/betterguac/initial-admin.txt        (mode 0600)
```

inside the container (and in the `bgdocker_conf` volume on the host). Read it
with:

```sh
docker compose exec betterguac cat /etc/betterguac/initial-admin.txt
```

It is **not** printed to `docker logs`, the init log or this README. The
password is also not re-generated on restart: `betterguac-setup` only creates
the admin if the database has no `ADMINISTER` permission rows, so a restart
with the marker present does not touch it.

### Where things are

| Path (in container)                | What |
| ---------------------------------- | ---- |
| `/etc/betterguac/guacamole.properties` | web app + DB login (root:tomcat 640) |
| `/etc/betterguac/guacd.conf`       | guacd config (127.0.0.1:4822) |
| `/etc/betterguac/keys/`            | SSH private keys (root:tomcat 0751) |
| `/etc/betterguac/betterguac.yaml`  | YAML servers/users (0600) |
| `/etc/betterguac/sync.env`         | YAML-sync DB login (0600) |
| `/etc/betterguac/initial-admin.txt`| first admin password (0600) |
| `/var/lib/betterguac/`             | `admin-user`, `.initialized` marker |
| `/var/lib/mysql/`                  | MariaDB datadir |
| `/var/log/betterguac-init.log`     | first-run init transcript |
| `/var/log/supervisor/`             | `mariadb.log`, `guacd.log`, `tomcat.log`, `supervisord.log` |

Logs are on stdout/stderr too (`docker compose logs -f betterguac`), because
supervisord is the container's main process.

## Volumes

| Volume           | Holds |
| ---------------- | ----- |
| `bgdocker_db`    | MariaDB datadir (`/var/lib/mysql`) |
| `bgdocker_conf`  | `/etc/betterguac`: properties, keys, YAML, sync.env, initial-admin, extension symlinks |
| `bgdocker_state` | `/var/lib/betterguac`: admin-user, init marker |
| `bgdocker_logs`  | `/var/log/betterguac`: init log (supervisor logs live in the container FS) |

The named volume at `/etc/betterguac` hides the image's directory, so on the
first boot the entrypoint copies the image's `/etc/betterguac` into the volume
and re-creates the extension/JAR symlinks the package ships. This is why
`/etc/betterguac/extensions/*.jar` still resolve after the first boot.

## Supervisor choice

`supervisord` (Debian `supervisor` 4.2.5) was chosen over s6/runit because it
is packaged in trixie, needs no PID 1, has per-program `autostart`,
`autorestart`, `startsecs`, `startretries`, `stopsignal`, `stopwaitsecs` and
log redirection, and `supervisorctl` gives a clear status/restart interface
for the crash tests. s6/runit would work but adds a supervision tree and
service-definition format for no benefit here.

`tini` is the entrypoint (`-g`, so it signals the whole process group) and
reaps zombies. Compose `init: false` because tini is already PID 1; using both
would double-init.

## First-run init and readiness

1. `/var/lib/betterguac/.initialized` present → log "skipping first-run init"
   and `exec supervisord`.
2. No marker but datadir/state already present → **refuse** to touch anything
   and print the recovery steps (`docker compose down -v` then `up -d`).
   This is the half-init detection; nothing is deleted or regenerated.
3. Otherwise: `mariadb-install-db`, start a temporary `mariadbd` (foreground,
   socket only), run `/usr/lib/betterguac/betterguac-setup configure` (the
   package's own script: DB + schema + admin + YAML sync + Tomcat context),
   verify the admin row and config files, shut MariaDB down cleanly, write the
   marker, `exec supervisord`.

Readiness: `mariadb` has priority 10; `guacd` (20) and `tomcat` (30) are
started through `betterguac-wait-for-db`, which blocks on
`mariadb-admin --protocol=socket -uroot ping` before `exec`-ing the real
process. Priorities alone are not readiness; the wrapper is the gate.

## Health

`healthcheck.sh` checks `GET /betterguac/` = 200, guacd on 4822 and MariaDB
ping. Compose runs it every 15s with a 90s start period. Health checks only
report: individual service restarts are supervisord's job, the whole container
is restarted by `restart: unless-stopped`.

## Package postinst workaround (why the build looks like this)

The .deb's postinst runs `betterguac-setup configure`, whose `wait_for_db`
only starts MariaDB via systemd/`invoke-rc.d`. In a systemd-free container
`invoke-rc.d` is denied by policy and systemd is absent, so the configure step
fails and dpkg leaves the package `install ok half-configured`. A later
`dpkg --configure -a` does not retry it (the package is no longer in the
unpacked state).

The Dockerfile works around this **inside the image only** (the .deb is not
modified):

1. `policy-rc.d` denies all `invoke-rc.d` starts during install.
2. Dependencies (including `mariadb-server` so `mariadbd-safe` exists) are
   installed first; `dpkg -i --force-depends` unpacks the .deb; the postinst
   fails as expected.
3. `mariadbd-safe` is started, then `dpkg --configure betterguac` runs the
   package's own `betterguac-setup configure` **once**, with an empty
   debconf password so the package generates the admin password.
4. MariaDB is shut down, `/var/lib/mysql` is deleted, and every build-time
   secret (`guacamole.properties`, `sync.env`, `betterguac.yaml`,
   `initial-admin.txt`, `admin-user`) is removed. The first container boot
   regenerates them, so no dummy password is baked into any layer.

The image still has the package registered `install ok installed` (verified by
`dpkg -s betterguac` in the image).

## Backup and restore

The database and all secrets live in the named volumes. A consistent logical
backup is a `mariadb-dump` of the two product databases:

```sh
cd ~/betterguac-docker
docker compose exec -T betterguac sh -c \
  'mariadb-dump --protocol=socket -uroot --single-transaction \
     --databases betterguac betterguac_yamlsync' > betterguac-backup.sql
```

The config volume is plain files; archive it with `docker run --rm -v
bgdocker_conf:/data -v "$PWD":/out alpine tar czf /out/bgdocker-conf.tgz -C
/data .` (or copy `/etc/betterguac` out of the container). Note that
`initial-admin.txt`, `sync.env` and `guacamole.properties` contain secrets.

Restore: stop the stack, restore the volumes (e.g. `docker compose down`, then
`docker run --rm -v bgdocker_db:/data -v "$PWD":/out alpine sh -c 'rm -rf
/data/*; tar xzf /out/db.tgz -C /data'`), then `docker compose up -d`. If you
restore a DB dump instead, `mysql < dump.sql` after boot and remove the
`.initialized` marker is **not** needed (the dump already contains the admin
row); restart the container.

## Rollback / cleanup

Stop the stack (keeps volumes):

```sh
cd ~/betterguac-docker && docker compose down
```

Remove only the bgdocker resources, volumes included (destroys all data):

```sh
cd ~/betterguac-docker && docker compose down -v
docker volume rm bgdocker_db bgdocker_conf bgdocker_state bgdocker_logs
docker network rm bgdocker_net
docker rmi betterguac:1.6.0-bg6-arm64
```

`docker compose down -v` already removes the project's named volumes and
network; the explicit commands are for when you ran `down` earlier. Nothing
outside the `bgdocker` project (and the `bgdocker-*` container) is touched by
any of these commands.

## Verification

```sh
cd ~/betterguac-docker
tests/run-tests.sh
```

The suite writes `test-results/` and `test-results/SUMMARY.txt`. It covers
build/arm64, clean first boot, `supervisorctl` status, listening ports, HTTP
200/redirect, admin row, `kill -9` crash recovery for mariadbd/guacd/java with
RestartCount/StartedAt unchanged, clean stop/start with checksum comparison,
down/up recreate with a canary row, and a second crash test after recreate.

## Not tested / out of scope

- Real SSH/RDP/VNC/Telnet sessions through guacd (no target servers).
- Host reboot / restart policy across a host restart.
- Multi-arch (amd64) builds.
- Registry publish.
- UI changes.
- Changes to the .deb itself (the package is used as-is; suggestions are in
  `suggested-package-patches/`, not applied).
- `betterguac-sync` plan/apply against the YAML (only the `init` step the
  package runs at setup is exercised).
- TOTP enrollment/sign-in flow.