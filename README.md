# BetterGuac

BetterGuac is a clientless remote access gateway for SSH, RDP, VNC and Telnet, built on Apache Guacamole 1.6.0. One package installs the whole stack on a single Linux machine: the connection daemon, the web application, a MariaDB database, two-factor sign-in, a modern interface, and a YAML tool that lets you manage servers and users as a file you can review, version and preview before anything changes.

Your users open a browser, sign in with their email address and an authenticator code, and see only the servers you assigned to them. No VPN client, no browser plugin, no Java applet.

> This README describes release 1.6.0+bg11. It is a full release as of November 23, 2026; it was a pre-release until then. Full release means it passed the tests listed under "Tested / not yet tested", not that every platform has been tested.

## Contents

- What you get
- Security status
- Tested / not yet tested
- Requirements
- Install
- First sign-in
- Managing servers and users with YAML
- SSH keys
- Running behind a reverse proxy
- Day-to-day administration
- Removing BetterGuac
- Troubleshooting
- Building the package from source
- License and credits

## What you get

- **One install.** guacd, Tomcat 10, MariaDB, the two-factor extension and the BetterGuac interface are installed and wired together by the package. No JAR files to copy, no schema to load by hand.
- **Two-factor sign-in built in.** Users enroll an authenticator app (it appears as "BetterGuac") the first time they sign in.
- **Email sign-in.** Accounts use an email address as the sign-in name.
- **Roles.** Administrators manage users, servers and assignments. Regular users manage their own profile and see only the servers assigned to them.
- **YAML as a source of truth.** Describe servers and users in one file, preview the exact changes, then apply them by plan ID.
- **SSH keys by path.** Private keys stay as files on the gateway. They are never pasted into a browser or stored as key text in the database.
- **RDP fix included.** guacd ships with a FreeRDP 3 post-connect graphics fix.
- **Activity log.** Administrators see who signed in, failed sign-ins, two-factor events, server sessions with their length, admin changes and YAML sync applies on the Activity page, with filters, search and CSV export. Activity is kept for 365 days by default.
- **Automatic database updates.** Upgrades apply BetterGuac's numbered database changes in order, after a backup of the database.
- Security refresh (new in bg11). Tomcat 10.1.62 bundled in the Debian/Ubuntu package and Docker image, clustering jars removed, all 9 Tomcat Critical findings from bg10 are gone from the Docker image. Newer libraries in the .deb, Arch packages and Docker image: Jackson 2.21.8, Guava 33.8.0, Logback 1.5.38, MyBatis 3.6.0. MariaDB Connector/J 2.7.15 bundled in the .deb and Arch packages and in the Docker image; the .deb no longer depends on libmariadb-java or tomcat-jakartaee-migration. The .deb files were rebuilt on November 23, 2026 with the same version: they run the bundled Tomcat as their own `betterguac-web` service instead of pulling in the distribution's `tomcat10`, and require FreeRDP 3.32.2 or later (on Debian 13, from trixie-backports).

## Security status

bg11 is a security update. It reduces Scout findings but doesn't clear them. bg11 changes no features or database schema; no migration runs on upgrade from bg10. In the Docker image, Docker Scout reports 3 Critical findings, all in freerdp3 3.33.1: CVE-2026-121392, CVE-2026-121952, and CVE-2026-121953. That's down from 12 Critical in bg10. Total findings went from 414 in bg10 to 306 (amd64) and 307 (arm64) in a Scout scan of the refreshed bg11 image on November 23, 2026: 3 Critical on both, 86 High on amd64 and 87 on arm64. Scout's totals move as its database changes, so treat them as a snapshot. The upstream fix landed in FreeRDP 3.32.2 and is included in 3.33.1, while Debian's trixie tracker has not marked the package fixed, so Scout still counts them. In that scan Scout lists one fixable High, in the arm64 image: CVE-2026-23949 in jaraco-context 6.0.1, fixed in 6.1.0. The top-scoring Highs are FreeRDP. Arch keeps Tomcat 10.1.61, which still lacks four fixes from 10.1.62.

**Debian/Ubuntu package rebuild, November 23, 2026.** The .deb files on the bg11 release were rebuilt with the same version, 1.6.0+bg11. The earlier .deb depended on the distribution's `tomcat10` package, so on Debian 13 it also installed Tomcat 10.1.60, and it accepted Debian 13's FreeRDP 3.15.0. A Docker Scout scan of a Debian 13 container with that package installed showed 12 Critical and 101 High findings. The rebuilt package runs the bundled Tomcat 10.1.62 as the `betterguac-web` service, no longer installs `tomcat10`, and requires FreeRDP 3.32.2 or later. The same scan of Debian 13 with the rebuilt package and FreeRDP 3.33.1 from trixie-backports shows 3 Critical and 86 High, on amd64 and arm64, and no Tomcat findings. The 3 Criticals and 75 of the Highs are FreeRDP entries that Debian's security tracker lists as fixed in 3.32.2 or earlier but still open for trixie, so Scout counts them against 3.33.1 from backports. The other 11 Highs (4 in OpenSSL, 2 in libxml2, 2 in libwebsockets, 2 in expat, 1 in speex) have no Debian fix yet; they are the same 11 as in the Docker image. On Ubuntu 26.04 the scan shows 0 Critical and 0 High with both the earlier and the rebuilt package. Scout's numbers are a snapshot from November 23, 2026.

## Tested / not yet tested

Tested in bg11: .deb fresh installs and bg10 upgrades in Debian 13 and Ubuntu 26.04 containers, amd64 and arm64, sign-in, MFA, YAML sync, SSH, RDP and VNC, Activity, database migration check (no schema change). Docker fresh start 18 of 18, upgrade on bg10 volumes 29 of 29, amd64 and arm64. Arch install suite 87 of 87 and MariaDB checks 7 of 7, x86_64 and aarch64, upgrades from bg10-1 and bg10-3. Two real Ubuntu 26.04 servers, upgraded from bg10, Tomcat 10.1.62, data unchanged; on the production server, with the earlier bg11 .deb, the owner signed in with two-factor and used SSH, RDP to two Windows servers, and two Cisco switches.

Tested for the rebuilt .deb (November 23): fresh installs in Debian 13 (with trixie-backports) and Ubuntu 26.04 arm64 containers, 79 of 79 checks each, including RDP and VNC sessions through guacd and the web app; a fresh install in a Debian 13 amd64 container (with trixie-backports), 67 of 67 checks including RDP and VNC; an upgrade from the earlier bg11 .deb in a Debian 13 amd64 container, 71 of 72 checks; upgrades from the earlier bg11 .deb in Debian 13 and Ubuntu 26.04 arm64 containers and from bg10 in a Debian 13 arm64 container, data and settings unchanged (the check for a pre-migration database backup did not pass because bg11 has no migration to run); one real Ubuntu 26.04 amd64 server upgraded from the earlier bg11 .deb with `--reinstall` and the distribution's Tomcat removed afterwards, health check 5 of 5, users, connections and two-factor setups intact.

Tested later on November 23, outside containers and in the remaining container: a fresh install of the rebuilt .deb on a Debian 13.8 amd64 KVM virtual machine on Proxmox (trixie-backports, FreeRDP 3.33.1), 67 of 67 checks including RDP and VNC sessions through guacd and the web app, then after a reboot of the VM all services, sign-in, RDP and VNC working again, 11 of 11; an upgrade from the earlier bg11 .deb on a second Debian 13 amd64 VM, 71 of 72 checks, data and settings unchanged, and the web app still working after the distribution's Tomcat was removed (the one miss is the same pre-migration backup check); a fresh install in an Ubuntu 26.04 amd64 container, 67 of 67 checks including RDP and VNC, and an upgrade from the earlier bg11 .deb in that container, 70 of 71 checks, data unchanged (same backup check); on the real Ubuntu 26.04 amd64 server running the rebuilt package, RDP and VNC sessions through guacd and through the web app, to a temporary Linux test desktop (xrdp and TigerVNC) on the local network. Every test used the published rebuilt amd64 .deb, SHA256 c7cd3686ac78bf2e3191e06af64f4dfbe591b5ec96d0d599f46adb4ecda83cdd.

Direct upgrade from bg9, tested November 23: on a third Debian 13 amd64 KVM virtual machine on Proxmox, the public bg9 .deb (SHA256 4cbdf03860f3eb818720769bb3e6ab0b1dd4ca2dddbb67b4674536542468b649) was installed with Debian 13's tomcat10 and FreeRDP 3.15.0, given two connections, a YAML user and an RDP session, then upgraded straight to the rebuilt bg11 .deb (same SHA256 as above) with FreeRDP 3.33.1 from trixie-backports. 72 of 72 checks passed: a database backup was taken before the one schema change (001-audit-log) was applied; connections, users, permissions, user attributes and connection history were unchanged; the files in /etc/betterguac were unchanged; RDP and VNC sessions worked through guacd and the web app; and the web app kept working after the distribution's Tomcat was removed. After a reboot of the VM, services, sign-in, RDP and VNC came back, 11 of 11. These sessions went to a temporary Linux test desktop (xrdp and TigerVNC) inside the VM.

Not yet tested: Debian 13 on physical hardware, the bg11 .deb has run on Debian 13 amd64 VMs and in containers only. Arch on real machines or VMs, containers only. Any arm64/aarch64 install outside a container. An RDP session to a Windows host through the rebuilt .deb: the real-server sessions above went to a Linux test desktop. An upgrade straight to bg11 from a release older than bg9, only bg9 to bg11 and bg10 to bg11 were tested. Before bg11, bg9 passed 12 basic checks on a Debian 13 amd64 Proxmox VM and on an emulated Debian 13 arm64 VM.

## Requirements

| Item | Supported |
|---|---|
| Operating system | Debian 13, Ubuntu 26.04 (`.deb`); Arch Linux (`.pkg.tar.zst`); anything else with Docker |
| Architecture | amd64 / x86_64, arm64 / aarch64 |
| Privileges | root or sudo |
| Network port | 8080/tcp (Tomcat) |

The package depends on MariaDB, a Java runtime and FreeRDP 3.32.2 or later, and pulls them in automatically. It runs the web application on the Apache Tomcat 10.1.62 release it ships, so it doesn't install the distribution's `tomcat10` package. Debian 13 takes FreeRDP from trixie-backports, see below.

**RHEL, Rocky Linux, AlmaLinux, CentOS and Fedora:** there is no RPM package. Use the Docker image, see [Docker](#docker).

**Important:** BetterGuac stores its data in MariaDB. Installing it on a machine that already runs MySQL replaces MySQL with MariaDB. Use a dedicated machine or VM.

## Install

### Debian and Ubuntu

Download the package for your architecture, then install it with `apt` so dependencies are resolved.

**Ubuntu 26.04:**

```bash
# amd64
sudo apt install ./betterguac_1.6.0+bg11_amd64.deb

# arm64
sudo apt install ./betterguac_1.6.0+bg11_arm64.deb
```

**Debian 13:** BetterGuac needs FreeRDP 3.32.2 or later, which has the fixes for the three FreeRDP Critical issues and most of the FreeRDP Highs. Debian 13's own FreeRDP is 3.15.0, so turn on Debian's official backports and take FreeRDP from there, the same FreeRDP 3.33.1 the Docker image uses:

```bash
echo "deb http://deb.debian.org/debian trixie-backports main" | sudo tee /etc/apt/sources.list.d/trixie-backports.list
sudo apt update
# amd64 (use the _arm64.deb on arm64)
sudo apt install ./betterguac_1.6.0+bg11_amd64.deb \
  libfreerdp3-3/trixie-backports libfreerdp-client3-3/trixie-backports libwinpr3-3/trixie-backports
```

Only FreeRDP and the few libraries it needs come from backports; everything else stays on Debian 13. Without backports, `apt` stops with "Depends: libfreerdp3-3 (>= 3.32.2~)".

**Already running bg11 from an earlier download:** the package keeps the version `1.6.0+bg11`, so add `--reinstall` to the same command (on Debian 13 with the backports part too). Your settings, keys and database stay as they are. The web app moves from the `tomcat10` service to `betterguac-web` and `tomcat10` is turned off; afterwards `sudo apt remove tomcat10 tomcat10-common libtomcat10-java` removes the distribution's Tomcat, which BetterGuac no longer uses.

The `./` matters: without it, `apt` looks for a package in your repositories instead of the file.

During installation you are asked two questions:

1. **Email address for the first administrator.** Leave it empty to create an account named `admin`.
2. **Password for the first administrator.** Leave it empty to have a long random password generated.

These questions appear only when you install from an interactive terminal. When the package is installed from a script or automation, it creates `admin` with a generated password. To choose the values in automation, preseed them before installing:

```bash
echo "betterguac betterguac/admin-email string admin@example.com" | sudo debconf-set-selections
sudo apt install -y ./betterguac_1.6.0+bg11_amd64.deb
```

### Arch Linux

Download the package for your architecture, then install it with `pacman -U`, which pulls in Tomcat 10, MariaDB, a Java runtime and the guacd libraries from Arch's repositories:

```bash
# x86_64
sudo pacman -U ./betterguac-1.6.0+bg11-1-x86_64.pkg.tar.zst

# aarch64 (Arch Linux ARM)
sudo pacman -U ./betterguac-1.6.0+bg11-1-aarch64.pkg.tar.zst
```

Use bg11-1. The earlier bg10-1 Arch packages are withdrawn: where they set up MariaDB themselves, MariaDB kept Arch's defaults, with anonymous accounts and listening on the LAN. Upgrading to bg10-3 or later, including bg11-1, closes that MariaDB automatically when the bg10-1 package set it up, and leaves a MariaDB set up any other way alone; your BetterGuac data is not touched. The MariaDB auto-close from bg10-3 is unchanged in bg11-1. The aarch64 package has been tested in Arch Linux ARM containers, not yet on a full Arch Linux ARM install.

Arch keeps its own tomcat10 package, 10.1.61 at build time, which still lacks four fixes from Tomcat 10.1.62 until Arch updates it.

The Arch package asks no questions. It initialises MariaDB, local only and with no anonymous accounts, if the machine has no database yet, creates the first administrator `admin` with a generated password, and enables and starts `mariadb`, `tomcat10` and `betterguac.target`. To choose the first administrator yourself, set `BETTERGUAC_ADMIN_EMAIL` (and optionally `BETTERGUAC_ADMIN_PASSWORD`) for the install: `sudo BETTERGUAC_ADMIN_EMAIL=admin@example.com pacman -U ./betterguac-...`.

Differences from the Debian package: Telnet is not included, because Arch has no `libtelnet` package (use Docker or the .deb for Telnet); Arch's Tomcat runs as the `tomcat10` user, so SSH key files are group `tomcat10` (see [SSH keys](#ssh-keys)); the notes for Arch are in `/usr/share/doc/betterguac/README.Arch`. The `PKGBUILD` is in `packaging/arch/` and is attached to the release.

### Docker

The image `bondjamesb07/betterguac` (amd64 and arm64) runs the whole stack in one container. This is the way to run BetterGuac on RHEL, Rocky Linux, AlmaLinux, CentOS, Fedora and any other Linux with Docker:

```bash
curl -fLO https://betterguac.org/download/compose.yaml
docker compose up -d --wait
docker compose exec betterguac cat /etc/betterguac/initial-admin.txt
```

Current Docker tags: 1.6.0-bg11 and latest, plus 1.6.0-bg11-amd64 and 1.6.0-bg11-arm64.

**Image refresh, November 23, 2026.** The 1.6.0-bg11 and latest tags now point to a rebuilt image (commit 14fc317 on main): Debian 13.8 with the Debian updates available at build time, and no curl, because the healthcheck now uses bash. The BetterGuac package inside is still 1.6.0+bg11, with no feature or database change, and it carries the bg11 libraries listed above. If you already run the bg11 image, pull it again and recreate the container; the named volumes, and your data in them, stay:

```bash
docker compose pull
docker compose up -d --wait
```

The Arch packages and the v1.6.0-bg11 tag were not rebuilt for the image refresh. The .deb files were rebuilt separately later the same day, see [Security status](#security-status); existing .deb installs switch with `--reinstall`, see [Debian and Ubuntu](#debian-and-ubuntu).

Then browse to `http://127.0.0.1:8080/betterguac/` on the Docker host. Port 8080 is published on loopback only; put a reverse proxy or a private tunnel in front for access from other machines.

Check downloads against SHA256SUMS on the [bg11 release](https://github.com/BondJamesB07/BetterGuac/releases/tag/v1.6.0-bg11) - `sha256sum -c SHA256SUMS --ignore-missing`

### Check the install

When installation finishes, check that everything is running:

```bash
sudo betterguac-admin status
```

Three services make up BetterGuac: `betterguac-guacd`, `betterguac-web` (the web application on the bundled Tomcat) and `mariadb`. All three start at boot. On Arch the web application runs on Arch's `tomcat10` service instead.

## First sign-in

Open `http://<server-address>:8080/betterguac/` in a browser. The bare address `http://<server-address>:8080/` and old `/guacamole/` bookmarks redirect there.

If you let the installer generate the password, read it from:

```bash
sudo cat /etc/betterguac/initial-admin.txt
```

The file is readable by root only. **Delete it once you have signed in and changed the password:** upgrades leave it in place, and after a password change it holds a stale password.

```bash
sudo rm /etc/betterguac/initial-admin.txt
```

### The setup administrator

The first account is a **setup administrator**. It signs in with the package-generated password and is **not** asked to enroll an authenticator app: it is meant to create the real administrators, and is then disabled or kept as a fallback with a long password.

1. Sign in as the first administrator with the generated password. No authenticator code is requested.
2. Create your own named administrator account (Users, New user, tick the administer permission) and enroll your authenticator at its first sign-in.
3. Disable the first administrator, or keep it as a break-glass account with a long random password.
4. Delete `/etc/betterguac/initial-admin.txt`.

This is the same idea as the first-run setup screen in tools like Portainer, with one difference: the setup screen is protected by a generated password instead of being open to whoever reaches it first. Accounts created afterwards, including a second administrator, are normal accounts and are asked to enroll an authenticator.

### Locked out

If an administrator loses its password or authenticator:

```bash
sudo betterguac-admin reset-password <username>
```

This prints a new password, re-enables the account if it was disabled, and clears its two-factor enrollment. The setup administrator also keeps its no-two-factor setting, so it still signs in with its password alone; other accounts enroll again at the next sign-in.

## Managing servers and users with YAML

You can manage everything in the web interface. For more than a handful of servers, the YAML sync is faster and safer: you describe the servers and users you want in a file, preview exactly what will change, and apply that preview.

### How it works

- **It only runs when you run it.** Nothing watches the file. Saving the file changes nothing until you apply a plan.
- **Preview first.** `plan` reads the database and shows every change. It writes nothing.
- **Apply exactly what you reviewed.** `apply` needs the plan ID that `plan` printed. If anything changed since the preview (the file or the database), it refuses and writes nothing.
- **It only manages what it created.** Servers and users created in the web interface are left alone, unless you hand one to the sync with `adopt`.
- **Web edits are respected.** If someone changes a managed field in the web interface, that edit is kept. If the YAML changed the same field too, the change is reported as a conflict and skipped.
- **Protected accounts.** `guacadmin` and the administrator created at install can never be created, changed or deleted by the sync.
- **Never touched:** two-factor secrets and enrollment, connection history, sharing profiles and user groups.
- **Removing an entry deletes it.** If you remove a server or user that the sync created from the file, the next plan deletes it. Safety checks stop a plan that would delete everything, or more than half of what the sync manages.

### The files

| File | Purpose |
|---|---|
| `/etc/betterguac/betterguac.yaml` | Your servers and users. Created by the installer as a starter file. |
| `/etc/betterguac/sync.env` | Secrets referenced by the YAML, plus the sync's database login. Root only. |
| `/etc/betterguac/keys/` | SSH private keys, referenced by path. |
| `/usr/share/betterguac/betterguac.yaml.example` | A complete example with every option. |

All commands need root, so run them with `sudo`.

### The four commands

Every command takes the **YAML file** as its argument. Not `sync.env`: the sync finds that file on its own.

```bash
# 1. Validate the file (syntax, names, secrets, key paths). Does not touch the database.
sudo betterguac-sync check /etc/betterguac/betterguac.yaml

# 2. Preview the changes. Reads the database, writes nothing, prints a plan ID.
sudo betterguac-sync plan /etc/betterguac/betterguac.yaml

# 3. Apply exactly that plan. Copy the plan ID from step 2.
sudo betterguac-sync apply /etc/betterguac/betterguac.yaml --confirm <plan-id>

# 4. See what the sync manages.
sudo betterguac-sync status
```

`--confirm` must be followed by the full plan ID. `--confirm` on its own is an error.

### Worked example: one server, one user

This example adds an SSH server called Web-01 and a user who can reach it.

**Step 1: store the user's password in `sync.env`.** Passwords never go in the YAML file. Add a line with a name of your choice:

```bash
sudo nano /etc/betterguac/sync.env
```

```ini
JANE_PASSWORD=Choose-A-Long-Initial-Password
```

Leave the existing lines in `sync.env` as they are; they hold the sync's database login.

**Step 2: install the SSH key** for the server on the gateway:

```bash
sudo install -o root -g tomcat -m 640 ./web-01.key /etc/betterguac/keys/web-01
```

**Step 3: edit the YAML file.**

```bash
sudo nano /etc/betterguac/betterguac.yaml
```

The starter file contains `connections: []` and `users: []` with commented examples underneath. The `[]` means "empty list". **When you add entries, delete the `[]`**, otherwise the file is not valid YAML. Leave the `instance:` line exactly as the installer wrote it: it ties the file to this machine's database.

The finished file looks like this:

```yaml
version: 1
kind: guacamole-db-sync
instance: betterguac            # keep the value the installer wrote

connections:
  - key: web-01                 # stable ID used by the sync; lowercase, never shown to users
    name: Web-01                # what users see
    group: Lab                  # optional folder
    protocol: ssh
    params:
      hostname: 192.0.2.10
      port: 22
      username: admin
      private-key-file: /etc/betterguac/keys/web-01

users:
  - username: jane@example.com
    email: jane@example.com
    full_name: Jane Example
    password: {env: JANE_PASSWORD}   # the name from sync.env
    password_mode: initial           # set once; Jane can change it later
    connections: [web-01]            # connection keys from above
```

**Step 4: check.**

```console
$ sudo betterguac-sync check /etc/betterguac/betterguac.yaml
OK: 1 connections, 1 users (instance betterguac)
  connection web-01: params hostname, port, private-key, private-key-file, username
```

**Step 5: plan.** The output looks like this (your plan ID will differ):

```console
$ sudo betterguac-sync plan /etc/betterguac/betterguac.yaml
Plan 7b0bd20ec94718fec5632e618d8485761f13e3d71cc6d457946d6e9bdd044d7a
  2 to create, 0 to update, 0 to delete, 0 conflicts, 0 unchanged

+ CREATE connection web-01
  ...
+ CREATE user jane@example.com
  ...

Nothing was written. To apply exactly this plan:
  betterguac-sync apply FILE --confirm 7b0bd20ec94718fec5632e618d8485761f13e3d71cc6d457946d6e9bdd044d7a
```

Passwords are never printed. The plan shows `(secret from env JANE_PASSWORD)` instead.

**Step 6: apply.** Replace `FILE` with the path of your YAML file and paste the plan ID:

```bash
sudo betterguac-sync apply /etc/betterguac/betterguac.yaml \
  --confirm 7b0bd20ec94718fec5632e618d8485761f13e3d71cc6d457946d6e9bdd044d7a
```

```console
Applied plan 7b0bd20e...: 2 created, 0 updated, 0 deleted, 0 conflicts skipped.
```

Jane can now sign in with her email and the initial password, and enrolls her authenticator at first sign-in.

### Field reference

**Top level** (all required except the lists, which may be empty):

| Field | Meaning |
|---|---|
| `version` | Always `1` |
| `kind` | Always `guacamole-db-sync` |
| `instance` | Short name tied to this machine's database. Keep the installer's value. |
| `connections` | List of servers |
| `users` | List of users |

**Connection fields:**

| Field | Required | Meaning |
|---|---|---|
| `key` | yes | Stable ID: lowercase letters, digits, `.` `_` `-` |
| `name` | yes | Display name, 1 to 128 characters |
| `protocol` | yes | `ssh`, `rdp`, `vnc`, `telnet` or `kubernetes` |
| `params` | no | Connection parameters, with Guacamole's parameter names (`hostname`, `port`, `username`, `password`, `security`, `ignore-cert`, `private-key-file`...) |
| `group` | no | Folder the connection appears in |
| `max_connections` | no | Limit on simultaneous sessions |
| `max_connections_per_user` | no | Limit per user |

**User fields:**

| Field | Required | Meaning |
|---|---|---|
| `username` | yes | Sign-in name, usually an email address |
| `password` | yes | `{env: NAME}` or `{file: /path}`, never plain text |
| `password_mode` | no | `initial` (default): set once, later changes by the user are kept. `managed`: the YAML value is enforced. |
| `email`, `full_name`, `organization`, `role`, `timezone` | no | Profile details |
| `connections` | no | List of connection keys this user may open |
| `admin` | no | `true` makes the user an administrator |
| `system_permissions` | no | Finer-grained alternative to `admin` (do not use both) |
| `disabled`, `expired` | no | `true` or `false` |
| `valid_from`, `valid_until` | no | Dates as `YYYY-MM-DD` |
| `access_window_start`, `access_window_end` | no | Times as `HH:MM` |

Secrets for connections work the same way, for example an RDP password:

```yaml
  - key: desktop-01
    name: Desktop-01
    protocol: rdp
    params:
      hostname: 192.0.2.20
      port: 3389
      username: user
      password: {env: DESKTOP01_PASSWORD}
      security: nla
      ignore-cert: true
```

### Bringing an existing object under YAML control

To let the sync manage a server or user you created in the web interface, add it to the YAML file with the same name, then:

```bash
# Preview
sudo betterguac-sync adopt /etc/betterguac/betterguac.yaml connection:web-01
# Do it
sudo betterguac-sync adopt /etc/betterguac/betterguac.yaml connection:web-01 --confirm
```

Use `user:<username>` for a user. From then on, `plan` shows any differences between the YAML and the database as updates.

### Options for plan and apply

| Option | Effect |
|---|---|
| `-v`, `--verbose` | Show more detail in the plan |
| `--json` | Machine-readable plan |
| `--strict` | Treat any conflict as an error |
| `--overwrite kind:key` | Let the YAML replace a web-interface edit on one object, for example `--overwrite connection:web-01` |
| `--allow-empty` | Allow a file with no entries to delete everything the sync manages |
| `--allow-mass-delete` | Allow a plan that deletes more than half of the managed objects |

**For scripts:** `plan` exits with code `0` when there is nothing to do, `2` when there are changes to apply, and `3` with `--strict` when there are conflicts. Code `2` is not an error.

## SSH keys

SSH private keys are files on the BetterGuac server, never text in the database or the browser.

```bash
sudo install -o root -g tomcat -m 640 ./mykey /etc/betterguac/keys/web-01
# Arch Linux: the group is tomcat10
sudo install -o root -g tomcat10 -m 640 ./mykey /etc/betterguac/keys/web-01
```

Then use `/etc/betterguac/keys/web-01` as the key file, in the web interface or as `private-key-file` in YAML. Rules:

- The key must live in `/etc/betterguac/keys/`.
- Use the full path. `~` and relative paths are not supported.
- Key files only work for `ssh` connections.

## Running behind a reverse proxy

BetterGuac serves its application at `/betterguac/` on port 8080. Point your proxy at that path and forward it unchanged.

Generic rule (any proxy):

- Public URL: `https://remote.example.com/betterguac/`
- Backend: `http://<server-address>:8080/betterguac/`
- Enable WebSocket upgrades. Remote sessions use them.
- Do not add, strip or rewrite path prefixes.

Example for nginx:

```nginx
location /betterguac/ {
    proxy_pass http://192.0.2.5:8080/betterguac/;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_buffering off;
}
```

**Client addresses in the Activity log.** Behind a proxy, Tomcat would see every request as coming from the proxy. BetterGuac's Tomcat context enables Tomcat's `RemoteIpValve`, which takes the client's address from `X-Forwarded-For`, but only when the request comes from a trusted proxy: loopback and private addresses (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 100.64.0.0/10, fc00::/7). Traefik, Caddy and the nginx example above send that header. If your proxy reaches BetterGuac from a public address, its requests are logged with the proxy's address; put the addresses to trust, as one regular expression in Tomcat's `internalProxies` format, in `/etc/betterguac/trusted-proxies`, then run `sudo betterguac-admin setup`. This replaces the default list, so include your private ranges too if you need them, for example:

```bash
echo '10\.\d{1,3}\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3}|203\.0\.113\.7' | sudo tee /etc/betterguac/trusted-proxies
sudo betterguac-admin setup
```

**Cloudflare (or another CDN) in front of your proxy.** Then the client's address has to be passed on by your proxy, not just by BetterGuac. Traefik, for example, replaces `X-Forwarded-For` with the CDN's address unless it trusts the CDN, so the Activity log shows Cloudflare's address. Tell Traefik to trust Cloudflare's ranges on the entry point (the current list is at https://www.cloudflare.com/ips/):

```yaml
entryPoints:
  https:
    address: ":443"
    forwardedHeaders:
      trustedIPs:
        - "173.245.48.0/20"
        - "103.21.244.0/22"
        # ...the rest of https://www.cloudflare.com/ips-v4 and /ips-v6
```

### Migrating from Apache Guacamole: remove old /guacamole rules

BetterGuac redirects old `/guacamole/...` addresses and the bare server address to the same path under `/betterguac/`, so existing bookmarks keep working. If your proxy still carries rules from a stock Guacamole setup that add or rewrite a `/guacamole` prefix (for example Traefik `addPrefix` or `replacePathRegex` middleware, or an nginx `proxy_pass` ending in `/guacamole/`), every request is sent back into that redirect, and each round trip adds another segment:

```text
/betterguac/
/betterguac/betterguac/
/betterguac/betterguac/betterguac/ ...
```

**Fix:** remove the old prefix middleware or rewrite and route straight to `/betterguac/` as shown above.

## Day-to-day administration

| Task | Command |
|---|---|
| Status of all services | `sudo betterguac-admin status` |
| Reset a password (also resets two-factor) | `sudo betterguac-admin reset-password <username>` |
| Database changes: list / apply | `sudo betterguac-admin migrate --status` / `sudo betterguac-admin migrate` |
| Rebuild the Tomcat 10 copy of the web application | `sudo betterguac-admin webapp` |
| guacd logs | `journalctl -u betterguac-guacd` |
| Web application logs | `journalctl -u betterguac-web` and `/var/log/tomcat10/` (Arch: `journalctl -u tomcat10`) |

**Where things live:**

| Path | Contents |
|---|---|
| `/etc/betterguac/guacamole.properties` | Web application settings and database login |
| `/etc/betterguac/guacd.conf` | guacd settings |
| `/etc/betterguac/keys/` | SSH private keys |
| `/etc/betterguac/betterguac.yaml` | YAML servers and users |
| `/etc/betterguac/sync.env` | Secrets and the sync's database login (root only) |
| `/usr/share/betterguac/` | Web application and extensions as shipped (`javaee/`), schema, examples |
| `/var/cache/betterguac/` | The web application and extensions converted for Tomcat 10 on this machine |
| `/var/lib/betterguac/backups/` | Database backups taken before database changes |
| `/usr/lib/betterguac/guacd/` | guacd and its protocol plugins |

## Removing BetterGuac

```bash
# Remove the program, keep settings, keys and the database for a later reinstall
sudo apt remove betterguac

# Remove everything, including /etc/betterguac (keys included) and the databases
sudo apt purge betterguac
```

Before a purge deletes the databases, a copy is saved to `/var/backups/betterguac-purge-<date>.sql.gz`. MariaDB, FreeRDP and Java stay installed; remove them with `sudo apt autoremove` if nothing else needs them.

On Arch Linux, `sudo pacman -R betterguac` removes the program and keeps `/etc/betterguac`, `/var/lib/betterguac` and the databases. pacman has no purge; to remove those too, back up, then drop the `betterguac` and `betterguac_yamlsync` databases and their two users, and delete the two folders. The exact commands are in `/usr/share/doc/betterguac/README.Arch`.

## Troubleshooting

**`error: the following arguments are required: file`**
The command needs the YAML file path: `sudo betterguac-sync check /etc/betterguac/betterguac.yaml`.

**`... is not valid YAML: while parsing a block mapping ... expected <block end>, but found '<block sequence start>'`**
You added entries under `connections: []` or `users: []` without deleting the `[]`. Change the line to `connections:` or `users:`.

**Passing `sync.env` to `apply`**
`apply` takes the YAML file, not `sync.env`. The sync reads `sync.env` automatically.

**`argument --confirm: expected one argument`**
Paste the plan ID after `--confirm`. Run `plan` again to see it.

**`the plan changed since you reviewed it ... Nothing was written; run plan again.`**
The YAML or the database changed after your preview. Run `plan` again, review it, and apply the new ID.

**`write the password as {env: NAME} or {file: PATH}, not inline`**
Move the password to `sync.env` as `NAME=...` and reference it with `{env: NAME}`.

**`environment variable NAME is not set`**
The name in `{env: NAME}` has no matching line in `sync.env`. Names must match exactly.

**`that is the key itself. Save it as a file ...`**
You pasted key text. Save the key in `/etc/betterguac/keys/` and give its path.

**`... is protected ... YAML may not manage it`**
`guacadmin` and the administrator created at install cannot be managed by YAML. Manage them in the web interface.

**`this YAML is for instance ... but the database is ...`**
The `instance:` line does not match this machine. Use the value the installer wrote.

**`can't read /etc/betterguac/sync.env (run it with sudo)`**
Run the command with `sudo`.

incompatible version of the Apache Tomcat Native library SEVERE at start on Ubuntu. Ubuntu servers with libtcnative-1 2.0.14 installed log one harmless SEVERE line at start. Tomcat then runs without the native library, as before.

## Building the package from source

The repository holds everything needed to build the `.deb` except three Apache Guacamole 1.6.0 release archives. They are large, unchanged upstream files, so `.gitignore` keeps them out of the repository. The build stops if any of them is missing from the `upstream/` folder.

| File | What the build uses it for |
|---|---|
| `guacamole-server-1.6.0.tar.gz` | Source of guacd, patched and compiled |
| `guacamole-auth-jdbc-1.6.0.tar.gz` | MySQL/MariaDB authentication extension and database schema |
| `guacamole-auth-totp-1.6.0.tar.gz` | Two-factor (TOTP) extension |

The fourth upstream file the build needs, `guacamole-1.6.0.war`, is already in `upstream/`.

These steps were tested on Debian 13. The package is built for the architecture of the machine you build on, so build on amd64 for an amd64 package and on arm64 for an arm64 package.

1. From the top folder of the repository, download the three archives into `upstream/` and check them against the SHA-256 checksums Apache publishes:

   ```bash
   cd upstream
   base=https://archive.apache.org/dist/guacamole/1.6.0
   curl -fLO "$base/source/guacamole-server-1.6.0.tar.gz"
   curl -fLO "$base/binary/guacamole-auth-jdbc-1.6.0.tar.gz"
   curl -fLO "$base/binary/guacamole-auth-totp-1.6.0.tar.gz"
   sha256sum -c <<'EOF'
   8bc45675da96d7b6f39728160181e3d4ff3c08f460f6d26de5805b642bf13f2b  guacamole-server-1.6.0.tar.gz
   97bc5fd3d67d25c0e98a475d1dfd308a037859f549fac47171c723b7a7039366  guacamole-auth-jdbc-1.6.0.tar.gz
   0202c197d3b4e59e69b4dde2a80906adf5f03a497748b74ad3d599022e26f347  guacamole-auth-totp-1.6.0.tar.gz
   EOF
   cd ..
   ```

   Each line must end in `OK`. The same files and `.sha256` checksum files are on Apache's download pages for [Guacamole 1.6.0](https://guacamole.apache.org/releases/1.6.0/).

2. Install the build tools and the build dependencies listed in `debian/control`:

   ```bash
   sudo apt install dpkg-dev fakeroot
   sudo apt build-dep ./
   ```

3. Build the package:

   ```bash
   dpkg-buildpackage -b -us -uc
   ```

   The package is written to the folder above the repository, for example `../betterguac_1.6.0+bg11_amd64.deb`. Install it as described in [Install](#install).

### Arch Linux package

`packaging/arch/PKGBUILD` builds the Arch package from the tagged release, the three Apache archives above, MariaDB Connector/J and the Apache Tomcat migration tool. On Arch or Arch Linux ARM:

```bash
cd packaging/arch
makepkg -si
```

## License and credits

BetterGuac is based on [Apache Guacamole](https://guacamole.apache.org/), used under the Apache License 2.0. The required license and notice files are included in the package, in `/usr/share/doc/betterguac/`. The MySQL authentication and two-factor extensions contain third-party libraries; their upstream LICENSE, NOTICE and per-library license files are kept in `/usr/share/doc/betterguac/guacamole-auth-jdbc/` and `/usr/share/doc/betterguac/guacamole-auth-totp/`. Apache Guacamole and Guacamole are trademarks of the Apache Software Foundation; BetterGuac is an independent project and is not endorsed by the Apache Software Foundation.

BetterGuac's changes to Apache Guacamole files are listed in `/usr/share/betterguac/legal/NOTICE`, and each changed file says so. The Apache Guacamole web application and its bundled third-party libraries (some under the Eclipse Public License 2.0 and CDDL 1.1) are shipped unmodified; they are converted from `javax.*` to `jakarta.*` for Tomcat 10 on the machine where BetterGuac is installed, with the Apache Tomcat migration tool (Debian's package of it in the `.deb`; the upstream release, shipped unmodified, in the Arch package). The Arch package also ships the stock MariaDB Connector/J jar (LGPL-2.1), because Arch does not package it. Where to get the source of BetterGuac, Apache Guacamole and those libraries is in `/usr/share/betterguac/legal/SOURCES`.

bg11 bundles the unmodified Apache Tomcat 10.1.62 release under /usr/share/betterguac/tomcat, minus the two clustering jars catalina-ha and catalina-tribes that BetterGuac does not use, in the Debian/Ubuntu package and Docker image. Arch uses its distribution Tomcat.

The Docker image is built on Debian and contains Debian packages under their own licenses, some under the GNU GPL (for example MariaDB and libvncclient). The image lists every package and version in `/usr/share/betterguac/legal/sbom/` (`packages.tsv` and an SPDX 2.3 file); their source is in the Debian archive at https://deb.debian.org/debian/pool/main/ and https://snapshot.debian.org/.
