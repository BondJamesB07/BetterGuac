#!/bin/bash
# Run guacd in the foreground, as root, with the package's config. The package's
# systemd unit uses DynamicUser (systemd-only); in the container guacd runs as
# root with a private HOME, which is the closest non-systemd equivalent. guacd
# only binds 127.0.0.1:4822 inside the container.
set -euo pipefail
export HOME=/var/lib/betterguac-guacd
exec /usr/lib/betterguac/guacd/sbin/guacd -f -c /etc/betterguac/guacd.conf