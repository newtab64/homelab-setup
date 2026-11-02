#!/usr/bin/env bash
#
# homelab-autoupdate.sh
#
# Daily maintenance script for homelab nodes:
# Runs package updates, cleans obsolete packages, flushes filesystem buffers, and reboots.
#

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

echo "=== Homelab Maintenance Started: $(date '+%Y-%m-%d %H:%M:%S') ==="

apt-get update
apt-get upgrade -y
apt-get autoremove --purge -y
apt-get autoclean

echo "=== Maintenance Completed. Syncing disks and rebooting: $(date '+%Y-%m-%d %H:%M:%S') ==="
sync

if command -v shutdown >/dev/null 2>&1; then
    shutdown -r now "Homelab scheduled daily maintenance reboot"
else
    reboot
fi
