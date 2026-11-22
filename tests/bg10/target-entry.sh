#!/bin/bash
# Throwaway RDP + VNC target for BetterGuac probes. Env: PW (probe user / VNC password)
set -u
id probe >/dev/null 2>&1 || useradd -m -s /bin/bash probe
echo "probe:$PW" | chpasswd
mkdir -p /root/.vnc
echo "$PW" | vncpasswd -f > /root/.vnc/passwd; chmod 600 /root/.vnc/passwd
Xvnc :5 -rfbport 5901 -SecurityTypes VncAuth -PasswordFile /root/.vnc/passwd -geometry 1024x768 -depth 24 -localhost=0 >/var/log/xvnc.log 2>&1 &
sleep 2
DISPLAY=:5 xterm -geometry 80x24+10+10 -e 'while :; do date; sleep 1; done' >/dev/null 2>&1 &
rm -f /etc/xrdp/key.pem /etc/xrdp/cert.pem
openssl req -x509 -newkey rsa:2048 -nodes -keyout /etc/xrdp/key.pem -out /etc/xrdp/cert.pem -days 2 -subj /CN=rdp-target >/dev/null 2>&1
if getent group xrdp >/dev/null; then chgrp xrdp /etc/xrdp/key.pem; fi
chmod 640 /etc/xrdp/key.pem
printf 'allowed_users=anybody\nneeds_root_rights=no\n' > /etc/X11/Xwrapper.config
mkdir -p /run/dbus; dbus-daemon --system --fork >/dev/null 2>&1 || true
xrdp-sesman --nodaemon >/var/log/sesman.out 2>&1 &
sleep 1
xrdp --nodaemon >/var/log/xrdp.out 2>&1 &
sleep 2
echo READY
wait
