#!/usr/bin/env bash
#
# homelab-setup.sh
#
# Quick-apply baseline setup for a fresh Ubuntu/Debian homelab server:
# - Automated daily maintenance cron job (apt update, upgrade, cleanup, and reboot at 00:00)
# - Strict IPv4-only SSH hardening (OpenSSH keys only, reduced timeouts and retries)
# - UFW firewall (IPv4 only, default deny incoming, SSH allowed)
# - Fail2ban for SSH brute-force defense
# - Optional laptop optimizations (ignoring lid-close suspend, TLP battery charge thresholds)
#
# Usage: sudo ./homelab-setup.sh
#

set -euo pipefail

# --- Validation Helpers ---

validate_yn() {
    local input="${1:-}"
    local default="${2:-n}"
    
    if [[ -z "$input" ]]; then
        input="$default"
    fi
    
    case "${input,,}" in
        y|yes)
            echo "y"
            return 0
            ;;
        n|no)
            echo "n"
            return 1
            ;;
        *)
            return 2
            ;;
    esac
}

validate_threshold() {
    local input="${1:-}"
    local default="${2:-}"
    local min="${3:-0}"
    local max="${4:-100}"
    
    if [[ -z "$input" ]]; then
        if [[ -n "$default" ]]; then
            input="$default"
        else
            return 1
        fi
    fi
    
    if [[ ! "$input" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    
    input=$((10#$input))
    
    if (( input < min || input > max )); then
        return 1
    fi
    
    echo "$input"
    return 0
}

validate_threshold_pair() {
    local start="${1:-}"
    local stop="${2:-}"
    
    if [[ ! "$start" =~ ^[0-9]+$ ]] || [[ ! "$stop" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    
    start=$((10#$start))
    stop=$((10#$stop))
    
    if (( stop <= start )); then
        return 1
    fi
    
    return 0
}

# --- Pre-flight Checks ---

if [[ $EUID -ne 0 ]]; then
    echo "Run this with sudo: sudo ./homelab-setup.sh" >&2
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIGS="$REPO_DIR/configs"
SSHD_CONFIG_LIVE="/etc/ssh/sshd_config"

for f in jail.local sshd_config; do
    if [[ ! -f "$CONFIGS/$f" ]]; then
        echo "Missing $CONFIGS/$f -- is this repo intact?" >&2
        exit 1
    fi
done

SSH_PORT="$(grep -iE '^[[:space:]]*Port[[:space:]]+[0-9]+[[:space:]]*$' "$CONFIGS/sshd_config" \
    | tail -n1 | awk '{print $2}')"
SSH_PORT="${SSH_PORT:-22}"

echo "=================================================="
echo "               Homelab Server Setup               "
echo "=================================================="
echo "This will apply the following base configuration:"
echo "  - Daily auto-update and reboot cron job (00:00)"
echo "  - Strict IPv4 SSH hardening (${SSH_PORT}/tcp, keys only)"
echo "  - UFW firewall (IPv4 only, incoming default deny, allow ${SSH_PORT}/tcp)"
echo "  - Fail2ban with the sshd jail"
echo

read -rp "Continue with setup? [y/N]: " reply
if ! validate_yn "$reply" "n" >/dev/null 2>&1 || [[ "$(validate_yn "$reply" "n")" != "y" ]]; then
    echo "Aborted. No changes made."
    exit 0
fi

# --- Optional Laptop Configuration Prompts ---

CONFIGURE_LID="n"
CONFIGURE_TLP="n"
TLP_START="45"
TLP_STOP="50"

echo
read -rp "Is this server running on a laptop? [y/N]: " is_laptop_reply
if validate_yn "$is_laptop_reply" "n" >/dev/null 2>&1 && [[ "$(validate_yn "$is_laptop_reply" "n")" == "y" ]]; then
    # Prompt for lid switch
    while true; do
        read -rp "  Ignore lid-close suspend (keep server running when lid is shut)? [Y/n]: " lid_reply
        status=0
        parsed_lid="$(validate_yn "$lid_reply" "y" 2>/dev/null)" || status=$?
        if (( status <= 1 )); then
            CONFIGURE_LID="$parsed_lid"
            break
        fi
        echo "  Please answer 'y' or 'n'."
    done

    # Prompt for TLP
    while true; do
        read -rp "  Install TLP for battery charge thresholds and powersave mode? [Y/n]: " tlp_reply
        status=0
        parsed_tlp="$(validate_yn "$tlp_reply" "y" 2>/dev/null)" || status=$?
        if (( status <= 1 )); then
            CONFIGURE_TLP="$parsed_tlp"
            break
        fi
        echo "  Please answer 'y' or 'n'."
    done

    if [[ "$CONFIGURE_TLP" == "y" ]]; then
        while true; do
            # Prompt start threshold
            while true; do
                read -rp "    Battery start charge threshold (0-99) [default: 45]: " start_raw
                if valid_start="$(validate_threshold "$start_raw" "45" 0 99 2>/dev/null)"; then
                    TLP_START="$valid_start"
                    break
                fi
                echo "    Invalid input. Enter an integer between 0 and 99."
            done

            # Prompt stop threshold
            while true; do
                read -rp "    Battery stop charge threshold (1-100) [default: 50]: " stop_raw
                if valid_stop="$(validate_threshold "$stop_raw" "50" 1 100 2>/dev/null)"; then
                    TLP_STOP="$valid_stop"
                    break
                fi
                echo "    Invalid input. Enter an integer between 1 and 100."
            done

            if validate_threshold_pair "$TLP_START" "$TLP_STOP"; then
                echo "    Configured battery thresholds: start at ${TLP_START}%, stop at ${TLP_STOP}%."
                break
            else
                echo "    Error: Stop threshold (${TLP_STOP}%) must be greater than start threshold (${TLP_START}%). Please re-enter."
            fi
        done
    fi
fi

echo
echo "Applying updates and configurations..."
apt-get update

# ---------- 1. Auto-update & Daily Reboot Setup (crontab) ----------
echo
echo "--- 1. Auto-update & Daily Reboot Setup (crontab) ---"
CRON_TAG="# homelab-autoupdate"
CRON_CMD="0 0 * * * DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y && apt-get autoremove --purge -y && apt-get autoclean && sync && (shutdown -r now || reboot) >> /var/log/homelab-autoupdate.log 2>&1 $CRON_TAG"

# Configure root crontab directly without placing extra scripts on the system
(crontab -l 2>/dev/null | grep -F -v "$CRON_TAG" || true; echo "$CRON_CMD") | crontab -
echo "  Configured root crontab to run daily update and reboot at 00:00."

# ---------- 2. Laptop Lid Switch Handling (Optional) ----------
if [[ "$CONFIGURE_LID" == "y" ]]; then
    echo
    echo "--- 2. Laptop Lid Handling ---"
    LOGIND_CONF="/etc/systemd/logind.conf"
    if [[ -f "$LOGIND_CONF" ]]; then
        sed -i -E 's/^#?[[:space:]]*HandleLidSwitch=.*/HandleLidSwitch=ignore/' "$LOGIND_CONF"
        sed -i -E 's/^#?[[:space:]]*HandleLidSwitchExternalPower=.*/HandleLidSwitchExternalPower=ignore/' "$LOGIND_CONF"
        sed -i -E 's/^#?[[:space:]]*HandleLidSwitchDocked=.*/HandleLidSwitchDocked=ignore/' "$LOGIND_CONF"
        sed -i -E 's/^#?[[:space:]]*LidSwitchIgnoreInhibited=.*/LidSwitchIgnoreInhibited=yes/' "$LOGIND_CONF"

        grep -q '^HandleLidSwitch=' "$LOGIND_CONF" || echo 'HandleLidSwitch=ignore' >> "$LOGIND_CONF"
        grep -q '^HandleLidSwitchExternalPower=' "$LOGIND_CONF" || echo 'HandleLidSwitchExternalPower=ignore' >> "$LOGIND_CONF"
        grep -q '^HandleLidSwitchDocked=' "$LOGIND_CONF" || echo 'HandleLidSwitchDocked=ignore' >> "$LOGIND_CONF"
        grep -q '^LidSwitchIgnoreInhibited=' "$LOGIND_CONF" || echo 'LidSwitchIgnoreInhibited=yes' >> "$LOGIND_CONF"
    else
        cat << 'EOF' > "$LOGIND_CONF"
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
LidSwitchIgnoreInhibited=yes
EOF
    fi
    rm -f /etc/systemd/logind.conf.d/00-homelab-lid.conf
    echo "  Updated /etc/systemd/logind.conf directly to ignore lid-close events."
    systemctl restart systemd-logind || true
    echo "  Reloaded systemd-logind."
fi

# ---------- 3. TLP Power & Battery Protection (Optional) ----------
if [[ "$CONFIGURE_TLP" == "y" ]]; then
    echo
    echo "--- 3. TLP Battery Management ---"
    apt-get install -y tlp
    rm -f /etc/tlp.conf
    cat << EOF > /etc/tlp.conf
START_CHARGE_THRESH_BAT0=${TLP_START}
STOP_CHARGE_THRESH_BAT0=${TLP_STOP}
CPU_SCALING_GOVERNOR_ON_AC=powersave
CPU_SCALING_GOVERNOR_ON_BAT=powersave
EOF
    echo "  Configured /etc/tlp.conf (BAT0: ${TLP_START}%-${TLP_STOP}%, powersave on AC/BAT)."
    systemctl enable --now tlp || true
    tlp start || true
fi

# ---------- 4. Firewall (UFW) ----------
echo
echo "--- 4. Firewall (UFW) ---"
apt-get install -y ufw

# Enforce IPv4 only in UFW
if [[ -f /etc/default/ufw ]]; then
    sed -i 's/^IPV6=.*/IPV6=no/' /etc/default/ufw
fi

ufw allow "${SSH_PORT}/tcp"
ufw default deny incoming
ufw default allow outgoing
ufw --force enable
ufw status verbose

# ---------- 5. Fail2ban ----------
echo
echo "--- 5. Fail2ban ---"
apt-get install -y fail2ban
cp "$CONFIGS/jail.local" /etc/fail2ban/jail.local
systemctl enable --now fail2ban || true
systemctl restart fail2ban
sleep 2
fail2ban-client status sshd || true

# ---------- 6. SSH Hardening (Strict IPv4) ----------
echo
echo "--- 6. SSH Hardening ---"
apt-get install -y openssh-server

BACKUP_DIR="$(dirname "$SSHD_CONFIG_LIVE")/sshd_config_backups"
mkdir -p "$BACKUP_DIR"
BACKUP="$BACKUP_DIR/sshd_config.$(date +%Y%m%d%H%M%S%N).bak"
cp "$SSHD_CONFIG_LIVE" "$BACKUP"
echo "  Backed up current config to $BACKUP"

cp "$CONFIGS/sshd_config" "$SSHD_CONFIG_LIVE"

if sshd -t; then
    systemctl restart ssh || systemctl restart sshd
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
echo "=================================================="
echo "                 Setup Complete!                  "
echo "=================================================="
echo "IMPORTANT: Test SSH login from a NEW terminal before closing this session:"
echo "  ssh -p ${SSH_PORT} user@serverip"
echo
echo "Maintenance logs will be written to:"
echo "  /var/log/homelab-autoupdate.log"
if [[ "$CONFIGURE_TLP" == "y" ]]; then
    echo
    echo "Verify laptop battery status with:"
    echo "  sudo tlp-stat -b"
fi
echo "=================================================="
