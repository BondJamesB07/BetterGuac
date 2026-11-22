# Suggested package patches (NOT applied to the .deb)

These are proposals for the next BetterGuac package release, written from the
findings of packaging this .deb into a systemd-free container. The installed
package in `bgdocker` is untouched; the Docker image works around each item in
its own layers (see the main README, "Package postinst workaround").

## 1. `betterguac-setup`: `wait_for_db` cannot start a database in a container

`wait_for_db()` only tries `systemctl start mariadb.service` (when
`/run/systemd/system` exists) or `invoke-rc.d mariadb start`. In a container
without systemd, both are no-ops: `invoke-rc.d` needs policy-rc.d to allow it,
and the policy in Debian images denies service starts. The result is:

```
betterguac: error: MariaDB isn't answering. Start it (systemctl start mariadb),
then run: sudo dpkg --configure -a
dpkg: error processing package betterguac (--configure):
 installed betterguac package post-installation script subprocess returned error exit status 1
```

and the package is left `install ok half-configured`. Worse, a later
`dpkg --configure -a` does not retry it (the package is not in the unpacked
state), so the suggested recovery command in the error message does not work;
`dpkg --configure betterguac` is required.

Suggested patch to `wait_for_db` in `/usr/lib/betterguac/betterguac-setup`
(idea only, not applied):

```diff
 wait_for_db() {
     local i
     for i in $(seq 1 30); do
         if sql -e 'SELECT 1' >/dev/null 2>&1; then return 0; fi
-        if [ "$i" = 1 ]; then
-            if have_systemd; then systemctl start mariadb.service >/dev/null 2>&1 || true
-            else invoke-rc.d mariadb start >/dev/null 2>&1 || true; fi
-        fi
+        if [ "$i" = 1 ] && ! sql -e 'SELECT 1' >/dev/null 2>&1; then
+            if have_systemd; then systemctl start mariadb.service >/dev/null 2>&1 || true
+            elif command -v mariadbd-safe >/dev/null 2>&1; then
+                # non-systemd (container, chroot): start the server directly
+                mariadbd-safe --skip-syslog >/var/log/mariadb-setup.log 2>&1 &
+            else invoke-rc.d mariadb start >/dev/null 2>&1 || true; fi
+        fi
         sleep 1
     done
     return 1
 }
```

A more conservative variant is to keep `wait_for_db` as-is and have postinst
print the correct recovery command (`dpkg --configure betterguac`, not
`dpkg --configure -a`).

## 2. `betterguac-setup`: systemd calls in `setup_tomcat` on a non-systemd host

`setup_tomcat()` runs, when `have_systemd` is true, `systemctl daemon-reload`,
`systemctl enable tomcat10 mariadb betterguac.target`, `systemctl restart
tomcat10.service` and `systemctl start betterguac.target`. In a container with
`/run/systemd/system` accidentally present (or in any non-systemd environment
that still has the directory), these calls fail noisily and `systemctl restart
tomcat10` aborts setup. `have_systemd()` should also verify that PID 1 is
systemd, e.g.:

```diff
-have_systemd() { [ -d /run/systemd/system ]; }
+have_systemd() { [ -d /run/systemd/system ] && [ "$(ps -p 1 -o comm= 2>/dev/null | tr -d ' ')" = systemd ]; }
```

## 3. postinst: the failure leaves no usable hint

The postinst's `configure` case exits on the `betterguac-setup` failure before
the `deb-systemd-helper` section, so `betterguac-guacd.service` and
`betterguac.target` are never enabled on a machine where the first configure
attempt raced MariaDB. That is benign for containers (we do not use the units)
but confusing for a real first install on a slow machine. Consider running the
systemd enablement in a trap/`|| true` so a DB hiccup does not leave the units
unenabled, or re-ordering so the DB step is last.

## 4. First-boot UX: print the password location on failure

If `create_admin` fails after `setup_database` (e.g. the schema import
failed), `/etc/betterguac/initial-admin.txt` may not exist and the only hint is
a generic error. Suggest wrapping the setup steps with a `trap` that prints the
partial state and the exact re-run command.

---

None of these patches are applied to `betterguac_1.6.0+bg6_arm64.deb`. The
container image works around all four items inside its own Dockerfile and
entrypoint.