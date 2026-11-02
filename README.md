# Homelab Setup Guide

A lightweight setup script and configuration baseline for fresh Ubuntu/Debian homelab servers: automated daily updates with a scheduled reboot, strict IPv4-only SSH key authentication, UFW firewall, fail2ban, and optional laptop optimizations (lid-close ignore and TLP battery charge thresholds).

Unlike enterprise environments requiring 99.999% uptime, homelab servers benefit from routine reboots to clear memory caches, apply kernel updates, and keep the system clean.

Keep your current SSH session open while running the setup. If something breaks, that open session is your way back in. Test changes from a second terminal before closing the first one.

---

## Repo layout

```
homelab-setup/
├── README.md
├── homelab-setup.sh
├── configs/
│   ├── homelab-autoupdate.sh
│   ├── jail.local
│   └── sshd_config
└── tests/
    ├── test_homelab_setup.sh
    └── test_validation.sh
```

Want to customize settings (SSH port, ban times, battery thresholds)? Fork this repo and edit the files under `configs/` directly. The setup script always reads from `configs/`.

---

## 1. Daily Auto-Update & Maintenance

Replaces heavy unattended-upgrades with a clean shell script executed daily at **00:00** via `/etc/cron.d/homelab-autoupdate`.

The maintenance script (`/usr/local/bin/homelab-autoupdate.sh`) executes:
1. `apt-get update`
2. `apt-get upgrade -y`
3. `apt-get autoremove --purge -y`
4. `apt-get autoclean`
5. `sync`
6. `shutdown -r now` (or `reboot`)

All output is logged with timestamps to `/var/log/homelab-autoupdate.log`.

To run maintenance immediately on-demand:
```bash
sudo /usr/local/bin/homelab-autoupdate.sh
```

---

## 2. SSH Key Authentication & Strict IPv4 Hardening

Password authentication is disabled in favor of `ed25519` keys, and the daemon is strictly restricted to IPv4.

### Prepare your key pair on your local PC:
```bash
ssh-keygen -t ed25519
ssh-copy-id -p 22 user@serverip
```

Confirm key login works before running the setup script!

### Key settings in `configs/sshd_config`:
- `AddressFamily inet` — IPv4 only (strictly refuses IPv6 connections).
- `Port 22` — Default SSH port (change to custom port if desired).
- `PermitRootLogin no` — Disables direct root login.
- `PasswordAuthentication no` — Keys only.
- `MaxAuthTries 3` — Drops connection after 3 failed attempts.
- `LoginGraceTime 30` — Closes unauthenticated sessions after 30 seconds.
- `ClientAliveInterval 300` / `ClientAliveCountMax 2` — Prunes disconnected sessions.
- `AllowAgentForwarding no` / `PermitUserEnvironment no` — Minimizes attack surface.

The setup script automatically backs up your existing `/etc/ssh/sshd_config` to `/etc/ssh/sshd_config_backups/`, validates the new configuration with `sshd -t`, and rolls back automatically if validation fails.

---

## 3. Firewall (UFW)

UFW blocks all unsolicited incoming traffic while allowing outbound connections:
- Enforces IPv4 only (`IPV6=no` in `/etc/default/ufw`).
- Opens the SSH port configured in `configs/sshd_config`.
- Sets default policy: deny incoming, allow outgoing.

---

## 4. Fail2ban

Monitors authentication logs for repeated failed attempts and bans offending IPs using iptables:
- Ban time: 7 days (`604800` seconds).
- Find window: 5 minutes (`300` seconds).
- Max retries: 3 attempts before temporary ban.

---

## 5. Laptop Optimizations (Optional)

When repurposing old laptops as 24/7 homelab nodes, `homelab-setup.sh` offers two optional configurations:

### A. Ignore Lid Switch
Closing the laptop lid normally suspends the machine. The script can configure systemd logind (`/etc/systemd/logind.conf.d/00-homelab-lid.conf`):
- `HandleLidSwitch=ignore`
- `HandleLidSwitchExternalPower=ignore`
- `HandleLidSwitchDocked=ignore`
- `LidSwitchIgnoreInhibited=yes`

This allows keeping the laptop screen closed without interrupting running services.

### B. TLP Battery Charge Thresholds & Powersave
Keeping laptop batteries plugged into AC at 100% capacity accelerates battery degradation and swelling. The script installs `tlp` and lets you set custom charge thresholds:
- Default start charge: `45%`
- Default stop charge: `50%`
- CPU governor on AC: `powersave`
- CPU energy performance policy: `power`

Check battery health and threshold status anytime with:
```bash
sudo tlp-stat -b
```

---

## Quick Setup

Clone the repository and run the setup script:

```bash
git clone <your-repo-url> homelab-setup
cd homelab-setup
chmod +x homelab-setup.sh
sudo ./homelab-setup.sh
```

The script asks for confirmation and prompts whether to apply laptop-specific tweaks (lid ignore and TLP thresholds).

---

## Running Offline Tests

You can run the included test suites without root privileges:

```bash
# Test input validation functions (integer bounds, defaults, y/n)
bash tests/test_validation.sh

# Comprehensive offline test suite (syntax, file generation, sshd validation)
bash tests/test_homelab_setup.sh
```

---

## Checklist

- [ ] SSH key generated on local PC and copied to server
- [ ] Confirmed SSH key login works before disabling passwords
- [ ] Base setup run (`sudo ./homelab-setup.sh`)
- [ ] Auto-update cron job verified in `/etc/cron.d/homelab-autoupdate`
- [ ] UFW enabled and IPv4-only verified (`sudo ufw status verbose`)
- [ ] Fail2ban active (`sudo fail2ban-client status sshd`)
- [ ] Tested SSH connection in a new terminal window
- [ ] (If laptop) Verified lid close does not suspend node
- [ ] (If laptop) Verified battery thresholds with `sudo tlp-stat -b`
