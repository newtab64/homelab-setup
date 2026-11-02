# Design Document: Homelab Setup & Auto-Maintenance

**Date**: 2026-11-02  
**Topic**: Refactoring server hardening into `homelab-setup` with scheduled maintenance & optional laptop profile  
**Status**: Pending Approval  

---

## 1. Intent and Why
The current repository (`server-hardening`) is designed as an enterprise-style baseline using Debian's `unattended-upgrades` package and general server security practices. In a homelab environment, 100% continuous uptime is not required, making scheduled daily reboots acceptable and desirable to cleanly clear caches, apply kernel updates, and keep the system lean.

Furthermore, many homelab users repurpose old laptops as low-power home servers. These systems require specific hardware handling: ignoring lid-close actions so the server remains active with the screen shut, and capping battery charging thresholds via TLP to prevent battery swelling and degradation when connected to AC power 24/7.

The objective is to pivot this repository into `homelab-setup`: a streamlined setup script for Debian/Ubuntu homelab nodes that replaces unattended-upgrades with an automated daily update-and-reboot cron job, enforces strict IPv4-only SSH access, sets up UFW and fail2ban, and provides optional laptop-friendly configurations (lid-close ignore and TLP battery/power management).

---

## 2. Goals, Non-Goals, and Anti-Goals

### Goals
- Rename the project and main script to `homelab-setup` and `homelab-setup.sh`.
- Remove `unattended-upgrades` package requirement and drop `configs/50unattended-upgrades`.
- Introduce a dedicated maintenance script (`configs/homelab-autoupdate.sh`) installed to `/usr/local/bin/homelab-autoupdate.sh` and scheduled at `00:00` daily via `/etc/cron.d/homelab-autoupdate`.
- Perform a complete update sequence during maintenance: `apt-get update`, `apt-get upgrade -y`, `apt-get autoremove --purge -y`, `apt-get autoclean`, `sync`, and `shutdown -r now`, redirecting output to `/var/log/homelab-autoupdate.log`.
- Enforce strict IPv4-only networking for SSH and firewall (no IPv6).
- Tighten SSH security settings with shorter timeouts, lower retry thresholds, session pruning, and disabled agent forwarding.
- Maintain UFW firewall (`IPV6=no`) and fail2ban protection for SSH.
- Provide interactive prompts during setup for optional laptop-specific tweaks:
  - Prompt to ignore lid-close suspend via `/etc/systemd/logind.conf.d/00-homelab-lid.conf`.
  - Prompt to install and configure TLP with powersave mode and customizable battery charge start/stop thresholds (defaults: 45% start, 50% stop).
- Update `README.md` to document the homelab philosophy, key steps, cron maintenance, laptop configurations, and setup instructions.

### Non-Goals
- Supporting non-Debian/Ubuntu distributions (e.g. RPM, pacman).
- Mandatory or forced laptop configuration for users running on desktops or mini PCs.
- Multi-battery threshold management beyond standard BAT0 / primary battery interfaces (handled gracefully if unsupported by hardware).

### Anti-Goals
- Enterprise 99.999% uptime constraints that avoid necessary system reboots.
- IPv6 dual-stack or IPv6 listeners.
- Silent cron failures without dedicated log files.

---

## 3. Constraints
- Must run cleanly on Debian and Ubuntu distributions with `sudo` / root privileges.
- All non-interactive flags must be set (`DEBIAN_FRONTEND=noninteractive`, `-y`) for automated commands to prevent `apt` from blocking waiting for console input.
- SSH configuration replacement must retain safety checks (backup to `/etc/ssh/sshd_config_backups/`, test with `sshd -t`, and rollback on failure).

---

## 4. Approaches Considered

### Approach 1: Dedicated Maintenance Script in `configs/` + Interactive Prompts (Selected)
- Provide `configs/homelab-autoupdate.sh` deployed to `/usr/local/bin/homelab-autoupdate.sh`.
- Deploy `/etc/cron.d/homelab-autoupdate` running at `0 0 * * *`.
- Offer interactive prompts during setup for optional laptop adjustments (lid handling and TLP).
- **Trade-offs**: Introduces a clean standalone script that users can manually run at any time (`sudo /usr/local/bin/homelab-autoupdate.sh`) for on-demand updates or debugging, and provides flexibility for both laptop and non-laptop homelab hardware.
- **Decision**: Chosen for maintainability, clarity, and modularity.

### Approach 2: Direct Inlined Cron One-Liner
- Drop a multi-command shell one-liner directly into `/etc/cron.d/homelab-autoupdate`.
- **Trade-offs**: Avoids adding `configs/homelab-autoupdate.sh`, but chaining multiple `apt` commands, `sync`, and `shutdown` in a single cron line makes manual testing and error tracing awkward and fragile.
- **Decision**: Rejected in favor of Approach 1.

---

## 5. Detailed Design Decided

### 5.1 Project Layout
```
homelab-setup/
├── README.md
├── homelab-setup.sh
└── configs/
    ├── homelab-autoupdate.sh
    ├── jail.local
    └── sshd_config
```

### 5.2 Auto-Update Maintenance (`configs/homelab-autoupdate.sh`)
- Script permissions: `0755`.
- Environment: `DEBIAN_FRONTEND=noninteractive`, `PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`.
- Steps:
  1. Print start timestamp to log.
  2. `apt-get update`
  3. `apt-get upgrade -y`
  4. `apt-get autoremove --purge -y`
  5. `apt-get autoclean`
  6. Print completion timestamp to log.
  7. `sync`
  8. `/sbin/shutdown -r now`
- Cron configuration (`/etc/cron.d/homelab-autoupdate`):
  ```cron
  0 0 * * * root /usr/local/bin/homelab-autoupdate.sh >> /var/log/homelab-autoupdate.log 2>&1
  ```

### 5.3 Stricter IPv4-Only SSH (`configs/sshd_config`)
- `AddressFamily inet` (strict IPv4 only, refuses IPv6).
- `Port 22` (default, customizable).
- `PermitRootLogin no`
- `PasswordAuthentication no`
- `KbdInteractiveAuthentication no`
- `MaxAuthTries 3`
- `LoginGraceTime 30`
- `ClientAliveInterval 300`
- `ClientAliveCountMax 2`
- `AllowAgentForwarding no`
- `PermitUserEnvironment no`
- `UsePAM yes`
- `X11Forwarding no`
- `PrintMotd no`
- `AcceptEnv LANG LC_* COLORTERM NO_COLOR`
- `Subsystem sftp /usr/lib/openssh/sftp-server`

### 5.4 Firewall (UFW) & Fail2ban
- In `/etc/default/ufw`, set `IPV6=no`.
- Open `${SSH_PORT}/tcp`.
- Set default deny incoming, default allow outgoing.
- Enable UFW.
- Install `fail2ban` and copy `configs/jail.local` to `/etc/fail2ban/jail.local`, restarting `fail2ban`.

### 5.5 Optional Laptop Power & Hardware Profile
During setup, `homelab-setup.sh` asks the user if they want to configure laptop-specific options:
1. **Lid-Close Handling**:
   - Prompt: `Ignore laptop lid-close suspend (keep server running with lid closed)? [y/N]`
   - Action: Writes `/etc/systemd/logind.conf.d/00-homelab-lid.conf`:
     ```ini
     [Login]
     HandleLidSwitch=ignore
     HandleLidSwitchExternalPower=ignore
     HandleLidSwitchDocked=ignore
     LidSwitchIgnoreInhibited=yes
     ```
   - Executes `systemctl restart systemd-logind`.
2. **TLP Battery & Energy Management**:
   - Prompt: `Install TLP for battery charge thresholds and powersave mode? [y/N]`
   - If yes:
     - Prompt: `Battery start charge threshold [default: 45]: ` (validates integer between 0-100, defaults to 45).
     - Prompt: `Battery stop charge threshold [default: 50]: ` (validates integer > start and <= 100, defaults to 50).
     - Installs `tlp`.
     - Writes `/etc/tlp.d/00-homelab.conf`:
       ```ini
       START_CHARGE_THRESH_BAT0=<start_val>
       STOP_CHARGE_THRESH_BAT0=<stop_val>
       CPU_SCALING_GOVERNOR_ON_AC=powersave
       CPU_ENERGY_PERF_POLICY_ON_AC=power
       ```
     - Enables and starts `tlp` service (`systemctl enable --now tlp`).

### 5.6 Main Setup Script (`homelab-setup.sh`)
- Validate running as root (`EUID -eq 0`).
- Check presence of `configs/homelab-autoupdate.sh`, `configs/jail.local`, and `configs/sshd_config`.
- Read SSH port dynamically from `configs/sshd_config`.
- Confirm with user before execution, including the optional laptop prompts.
- Execute steps in order:
  1. Base package installation & cron setup (`/usr/local/bin/homelab-autoupdate.sh` & `/etc/cron.d/homelab-autoupdate`).
  2. Optional laptop tweaks (lid ignore & TLP if requested).
  3. UFW configuration (`IPV6=no`, allow SSH port, default deny incoming, enable).
  4. Fail2ban setup.
  5. SSH configuration backup, replacement, validation (`sshd -t`), and restart.
- Print final summary with SSH connection verification command.

### 5.7 Documentation (`README.md`)
- Update project name, headings, and repository layout.
- Explain the homelab philosophy (daily midnight reboot, battery management, strict IPv4).
- Detail the daily maintenance routine, log location (`/var/log/homelab-autoupdate.log`), and manual trigger instructions.
- Detail laptop configuration options (lid switch behavior, TLP battery thresholds).
- Update checklist and quick-setup clone instructions.

---

## 6. What's Left to the Builder
- Removing `server-hardening.sh` and `configs/50unattended-upgrades` once `homelab-setup.sh` and `configs/homelab-autoupdate.sh` are in place.
- Ensuring appropriate log formatting with timestamps in `configs/homelab-autoupdate.sh`.
- Verifying bash syntax and script execution permissions.
