ARG BASE=archlinux:base
FROM ${BASE}
RUN (grep -q '^DisableSandbox' /etc/pacman.conf || sed -i 's/^\[options\]/[options]\nDisableSandbox/' /etc/pacman.conf) \
 && pacman -Syu --noconfirm --needed systemd python python-pymysql python-yaml openssh curl iproute2 inetutils procps-ng \
 && pacman -Scc --noconfirm
RUN sed -i "/^NoExtract/d" /etc/pacman.conf
RUN systemctl mask systemd-resolved.service getty@tty1.service console-getty.service systemd-firstboot.service systemd-networkd-wait-online.service >/dev/null 2>&1 || true
STOPSIGNAL SIGRTMIN+3
CMD ["/usr/lib/systemd/systemd"]
