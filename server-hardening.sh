#!/usr/bin/env bash
#
# server-hardening.sh
#
# Quick-apply hardening for a fresh Ubuntu/Debian server: unattended
# upgrades, UFW firewall, fail2ban, and SSH hardening. It does exactly one
# thing per service: copy/overwrite the matching file in configs/ into
# place. It does not ask for a port, does not ask about password auth, and
# does not let you pick individual services -- it applies all of them,
# as-is, from configs/.
#
# Want different values (port, password auth, ban times, etc.)? Don't
# answer a prompt -- fork this repo and edit the files under configs/
# directly. The script always reads from configs/, so your fork just works.
#
# SSH hardening REPLACES /etc/ssh/sshd_config with configs/sshd_config.
# The original is always backed up first (to /etc/ssh/sshd_config_backups/)
# and restored automatically if the new file fails `sshd -t`.
#
# Does NOT touch SSH keys. Generate and copy your key pair manually
# (see README section 2) and confirm key login works BEFORE running this
# script, since configs/sshd_config ships with PasswordAuthentication no.
#
# Usage: sudo ./server-hardening.sh

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Run this with sudo: sudo ./server-hardening.sh" >&2
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIGS="$REPO_DIR/configs"
SSHD_CONFIG_LIVE="/etc/ssh/sshd_config"

for f in 50unattended-upgrades jail.local sshd_config; do
    if [[ ! -f "$CONFIGS/$f" ]]; then
        echo "Missing $CONFIGS/$f -- is this repo intact?" >&2
        exit 1
    fi
done

# Read the port out of the config we're about to install, purely so the
# firewall opens the right one. Not a prompt, not a value the script
# invents -- it's just reading what's already in the file you'd fork and
# edit anyway. Falls back to 22 if the file doesn't set it.
SSH_PORT="$(grep -iE '^[[:space:]]*Port[[:space:]]+[0-9]+[[:space:]]*$' "$CONFIGS/sshd_config" \
    | tail -n1 | awk '{print $2}')"
SSH_PORT="${SSH_PORT:-22}"

echo "== Server Hardening =="
echo "This will, using the files in configs/ unmodified:"
echo "  - Install & configure unattended-upgrades"
echo "  - Enable UFW, default-deny incoming, allow ${SSH_PORT}/tcp"
echo "  - Install fail2ban with the sshd jail"
echo "  - Replace ${SSHD_CONFIG_LIVE} with configs/sshd_config (backed up first)"
echo
echo "Keep this SSH session open. Test a NEW connection before closing it."
echo
read -rp "Continue? [y/N]: " reply
[[ "${reply,,}" == y* ]] || { echo "Aborted. No changes made."; exit 0; }

apt update

# ---------- 1. unattended upgrades ----------
echo
echo "--- Unattended upgrades ---"
apt install -y unattended-upgrades
cp "$CONFIGS/50unattended-upgrades" /etc/apt/apt.conf.d/50unattended-upgrades
systemctl restart unattended-upgrades || true

# ---------- 2. firewall ----------
echo
echo "--- Firewall (UFW) ---"
apt install -y ufw
ufw allow "${SSH_PORT}/tcp"
ufw default deny incoming
ufw default allow outgoing
ufw --force enable
ufw status verbose

# ---------- 3. fail2ban ----------
echo
echo "--- fail2ban ---"
apt install -y fail2ban
cp "$CONFIGS/jail.local" /etc/fail2ban/jail.local
systemctl restart fail2ban
fail2ban-client status sshd || true

# ---------- 4. sshd hardening (full replace of the live file) ----------
echo
echo "--- SSH hardening ---"
apt install -y openssh-server

BACKUP_DIR="$(dirname "$SSHD_CONFIG_LIVE")/sshd_config_backups"
mkdir -p "$BACKUP_DIR"
BACKUP="$BACKUP_DIR/sshd_config.$(date +%Y%m%d%H%M%S%N).bak"
cp "$SSHD_CONFIG_LIVE" "$BACKUP"
echo "  Backed up current config to $BACKUP"

cp "$CONFIGS/sshd_config" "$SSHD_CONFIG_LIVE"

if sshd -t; then
    systemctl restart ssh
    echo "  sshd_config replaced and validated successfully."
else
    echo "  ERROR: new sshd_config failed validation (sshd -t). Restoring backup." >&2
    cp "$BACKUP" "$SSHD_CONFIG_LIVE"
    echo "  Restored $SSHD_CONFIG_LIVE from backup. No SSH changes were applied." >&2
    echo
    echo "== Done, with errors: SSH hardening failed and was rolled back ==" >&2
    exit 1
fi

echo
echo "== Done =="
echo "Test SSH login from a NEW terminal before closing this session:"
echo "  ssh -p ${SSH_PORT} user@serverip"