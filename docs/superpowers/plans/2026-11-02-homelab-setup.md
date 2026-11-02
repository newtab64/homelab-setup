# Homelab Setup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transform the server hardening repository into `homelab-setup`: an automated, clean setup script with daily cron maintenance, strict IPv4 SSH hardening, and interactive laptop hardware configurations (TLP battery thresholds & lid-close handling).

**Architecture:** Replace `unattended-upgrades` with a standalone maintenance script deployed to `/usr/local/bin/homelab-autoupdate.sh` and scheduled via `/etc/cron.d/homelab-autoupdate`. Harden SSH strictly for IPv4 with robust defense settings. Provide interactive prompts in `homelab-setup.sh` with thorough input validation for optional laptop lid-switch ignore and TLP battery charge thresholds. Provide automated test scripts to verify input validation, generated configs, and syntax in this Debian VM environment.

**Tech Stack:** Bash, Linux systemd (logind), OpenSSH Server, UFW, Fail2ban, TLP, Cron.

**Spec:** `docs/superpowers/specs/2026-11-02-homelab-setup-design.md`

## Global Constraints

- Must run on Debian and Ubuntu distributions with root (`EUID -eq 0`) privileges.
- Script and project renamed to `homelab-setup` and `homelab-setup.sh`.
- Auto-update maintenance must run daily at `00:00` with full non-interactive flags (`DEBIAN_FRONTEND=noninteractive`, `-y`) and output redirected to `/var/log/homelab-autoupdate.log`.
- Strict IPv4 only: `AddressFamily inet` in `configs/sshd_config` and `IPV6=no` in `/etc/default/ufw`.
- Input validation must reject non-integers, enforce bounds `[0, 100]`, and require `stop_threshold > start_threshold`.
- Test suite must run and pass in the local Debian VM without requiring root or active hardware triggers.

## Review Focus

1. **Non-numeric input for battery threshold**: When a user inputs strings (e.g. `abc`, `45%`, or empty spaces), validation must re-prompt without crashing.
2. **Stop threshold less than or equal to start threshold**: When start is `50` and user enters `40` for stop, validation must reject and re-prompt.
3. **Threshold out of bounds**: When user inputs `-5` or `105`, validation must reject and re-prompt with the allowed range.
4. **Invalid SSH config syntax**: `configs/sshd_config` must pass `/usr/sbin/sshd -t` without errors or unknown directives.
5. **Auto-update cron environment**: `configs/homelab-autoupdate.sh` must explicitly define `PATH` and `DEBIAN_FRONTEND=noninteractive` so scheduled cron execution does not stall on package prompts.

---

### Task 1: Create Auto-Update Script and Update SSH Config

**Files:**
- Create: `configs/homelab-autoupdate.sh`
- Modify: `configs/sshd_config`
- Delete: `configs/50unattended-upgrades`

**Interfaces:**
- Produces: `configs/homelab-autoupdate.sh` executable shell script.
- Produces: `configs/sshd_config` with strict IPv4 rules.

- [ ] **Step 1: Write `configs/homelab-autoupdate.sh`**
  Implement non-interactive maintenance script with explicit `PATH`, timestamp logging, `apt-get update`, `apt-get upgrade -y`, `apt-get autoremove --purge -y`, `apt-get autoclean`, `sync`, and `/sbin/shutdown -r now`.
- [ ] **Step 2: Update `configs/sshd_config`**
  Ensure:
  `AddressFamily inet`
  `MaxAuthTries 3`
  `LoginGraceTime 30`
  `ClientAliveInterval 300`
  `ClientAliveCountMax 2`
  `AllowAgentForwarding no`
  `PermitUserEnvironment no`
- [ ] **Step 3: Remove obsolete `configs/50unattended-upgrades`**
  Delete `configs/50unattended-upgrades`.
- [ ] **Step 4: Verify syntax and configuration**
  Run: `bash -n configs/homelab-autoupdate.sh && /usr/sbin/sshd -t -f configs/sshd_config`
  Expected: Command exits 0 with no errors.

---

### Task 2: Implement Input Validation & Unit Tests

**Files:**
- Create: `tests/test_validation.sh`

**Interfaces:**
- Produces: Bash validation functions:
  - `validate_yn(input, default)` -> returns `0` (yes) or `1` (no)
  - `validate_threshold(input, default, min, max)` -> validates integer within range, outputs integer, returns `0` on valid, `1` on invalid.
  - `validate_threshold_pair(start, stop)` -> ensures `stop > start`.

- [ ] **Step 1: Write test cases in `tests/test_validation.sh`**
  Cover:
  - Empty input fallback to default (e.g. empty -> 45, empty -> 50).
  - Valid integer (e.g. 45, 80).
  - Non-numeric input (`abc`, `50%`, `4 5`).
  - Negative numbers (`-10`) and numbers > 100 (`101`).
  - Inverted pair check (start 50, stop 40 -> fail; start 45, stop 50 -> pass).
- [ ] **Step 2: Implement validation functions in `tests/test_validation.sh`**
  Implement the validation helper logic in bash using integer regex `^[0-9]+$` and range checks.
- [ ] **Step 3: Run the validation test suite**
  Run: `bash tests/test_validation.sh`
  Expected: PASS on all test cases.

---

### Task 3: Implement Main Setup Script `homelab-setup.sh`

**Files:**
- Create: `homelab-setup.sh`
- Delete: `server-hardening.sh`

**Interfaces:**
- Consumes: Validation functions from Task 2.
- Consumes: `configs/homelab-autoupdate.sh`, `configs/sshd_config`, `configs/jail.local`.
- Produces: Complete root setup execution script.

- [ ] **Step 1: Create `homelab-setup.sh`**
  Implement the script with:
  - `EUID -eq 0` check.
  - Configuration files existence check.
  - `SSH_PORT` extraction from `configs/sshd_config` (fallback 22).
  - Summary display and user confirmation.
  - Interactive prompts for laptop options:
    - `Ignore laptop lid-close suspend? [y/N]`
    - `Install TLP for battery protection and powersave? [y/N]`
    - If TLP yes: prompt for start threshold (default 45), prompt for stop threshold (default 50), with retry loops until valid.
  - Step 1: Install `/usr/local/bin/homelab-autoupdate.sh` (chmod +x) and `/etc/cron.d/homelab-autoupdate` (`0 0 * * * root /usr/local/bin/homelab-autoupdate.sh >> /var/log/homelab-autoupdate.log 2>&1`).
  - Step 2 (Optional): If lid ignore, create `/etc/systemd/logind.conf.d/00-homelab-lid.conf` and restart `systemd-logind`.
  - Step 3 (Optional): If TLP, install `tlp`, write `/etc/tlp.d/00-homelab.conf`, start `tlp.service`.
  - Step 4: Configure UFW (set `IPV6=no` in `/etc/default/ufw`, allow `${SSH_PORT}/tcp`, default deny incoming, default allow outgoing, enable).
  - Step 5: Install fail2ban and deploy `configs/jail.local`.
  - Step 6: Backup `/etc/ssh/sshd_config`, copy `configs/sshd_config`, validate with `sshd -t`, restore on error, restart ssh.
  - Print final test instruction.
- [ ] **Step 2: Make `homelab-setup.sh` executable and remove `server-hardening.sh`**
  Run `chmod +x homelab-setup.sh && rm -f server-hardening.sh`.
- [ ] **Step 3: Syntax check**
  Run: `bash -n homelab-setup.sh`
  Expected: Command exits 0 with no syntax errors.

---

### Task 4: Comprehensive Test Suite for Dry-Run / Target Verification

**Files:**
- Create: `tests/test_homelab_setup.sh`

**Interfaces:**
- Consumes: `homelab-setup.sh`, `configs/homelab-autoupdate.sh`, `configs/sshd_config`, `configs/jail.local`.
- Produces: Automated test verifying file generations, drop-in config syntax, and mock executions without requiring root.

- [ ] **Step 1: Write `tests/test_homelab_setup.sh`**
  Mock system targets under a temporary directory `TARGET_DIR` and test:
  - Generated cron entry: matches `0 0 * * * root /usr/local/bin/homelab-autoupdate.sh >> /var/log/homelab-autoupdate.log 2>&1`.
  - Generated `/etc/systemd/logind.conf.d/00-homelab-lid.conf`: contains `HandleLidSwitch=ignore`.
  - Generated `/etc/tlp.d/00-homelab.conf`: contains valid `START_CHARGE_THRESH_BAT0=45` and `STOP_CHARGE_THRESH_BAT0=50`, plus powersave governors.
  - Verification that `IPV6=no` substitution works on `/etc/default/ufw`.
  - `sshd -t -f configs/sshd_config` passes.
- [ ] **Step 2: Execute test suite**
  Run: `bash tests/test_homelab_setup.sh`
  Expected: All checks report OK and exit 0.

---

### Task 5: Update Documentation (`README.md`)

**Files:**
- Modify: `README.md`

**Interfaces:**
- Produces: Fully updated user documentation.

- [ ] **Step 1: Update `README.md`**
  - Update title to `Homelab Setup Guide`.
  - Update repository layout diagram.
  - Document the daily auto-update maintenance routine (schedule, commands, `/var/log/homelab-autoupdate.log`, manual test command).
  - Document strict IPv4 SSH hardening settings.
  - Document optional laptop optimizations (lid ignore configuration, TLP battery threshold setup).
  - Update execution commands (`sudo ./homelab-setup.sh`) and checklist.
- [ ] **Step 2: Review links and accuracy**
  Ensure all references to `server-hardening.sh` and `50unattended-upgrades` are completely removed.
