# Server Hardening Guide

A simple checklist and script for locking down a fresh Ubuntu/Debian server:
automatic security updates, SSH key auth, a firewall, and fail2ban.

Keep your current SSH session open while you make changes. If something
breaks, that open session is your only way back in. Test every change in a
second terminal before closing the first one.

## Repo layout

```
server-hardening/
├── README.md
├── server-hardening.sh
└── configs/
    ├── 50unattended-upgrades
    ├── jail.local
    └── sshd_config
```

Want to use your own settings instead of the defaults? Fork this repo and
edit the files in `configs/` directly. The script always reads from
`configs/`, so your fork just works with your own values.

## 1. Unattended upgrades

Automatically installs security patches without you having to log in and
run `apt upgrade` manually. Unpatched packages are one of the most common
ways servers get compromised, so this closes a lot of doors on its own.

```bash
sudo apt install unattended-upgrades
sudo dpkg-reconfigure --priority=low unattended-upgrades
```

For finer control (which repos, reboot behavior, notifications), edit
`configs/50unattended-upgrades`.

## 2. SSH key authentication

A password is a secret you type. It can be guessed, brute-forced, phished,
or reused across sites. An SSH key pair is math, not a secret you memorize.
You generate two files: a private key (stays on your PC, never leaves it,
ideally protected by a passphrase) and a public key (safe to share, gets
copied to the server). When you connect, the server sends a challenge that
only your private key can answer correctly. Nothing secret ever travels
over the network, and there is no password to brute-force at all.

On the server, prepare the directory:

```bash
mkdir -p ~/.ssh
chmod 700 ~/.ssh
```

On your PC, generate a key pair:

```bash
mkdir -p ~/.ssh && cd ~/.ssh
ssh-keygen -t ed25519
ls
```

`ed25519` is the modern, recommended key type: smaller and faster than RSA
with equivalent or better security.

Copy the public key to the server:

```bash
scp ~/.ssh/id_ed25519.pub user@serverip:~/.ssh/authorized_keys
# or, more simply:
ssh-copy-id user@serverip
```

### Harden sshd_config

The key settings, already set in `configs/sshd_config`:

```
Port 22                # optional: change to a non-standard port to cut down
                        # on automated scan noise
AddressFamily inet      # IPv4 only, unless you specifically need IPv6
PermitRootLogin no      # never allow logging in directly as root
PasswordAuthentication no   # keys only, do this LAST, see warning below
```

Only disable `PasswordAuthentication` once you have confirmed key login
works, or you may lock yourself out.

`configs/sshd_config` is a complete config file, not a snippet. It keeps the
usual defaults (`Include`, `Subsystem sftp`, `UsePAM`, and so on) alongside
the hardening settings above, so it's safe to use as a full replacement.

`server-hardening.sh` automates this by backing up your current
`/etc/ssh/sshd_config` to `/etc/ssh/sshd_config_backups/`, then replacing it
entirely with `configs/sshd_config`, unmodified. It asks for one
confirmation before touching anything, validates the result, and rolls
back automatically if the new config is broken.

Test in a new terminal, without closing your current session, after running
the script or replacing the file yourself:

```bash
ssh user@serverip
```

## 3. Firewall (UFW)

UFW is a friendly front end for iptables. Default-deny on incoming traffic
means only the ports you explicitly allow are reachable. Everything else is
dropped before it reaches a service.

```bash
sudo apt install ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp
sudo ufw enable
sudo ufw status verbose
```

If you changed the SSH port in step 2, allow that port instead of 22, and
allow it before you enable the firewall, or you will lock yourself out.

## 4. fail2ban

Watches log files for repeated failed login attempts and temporarily bans
the offending IP at the firewall level. It turns repeated SSH brute-force
attempts into an automatic block after a few tries.

```bash
sudo apt install fail2ban
sudo cp configs/jail.local /etc/fail2ban/jail.local
sudo systemctl restart fail2ban
sudo fail2ban-client status sshd
```

Config used (`configs/jail.local`):

```ini
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1   # never ban yourself locally
bantime  = 604800             # ban length in seconds (7 days)
findtime = 300                 # window to count failures in (5 minutes)
maxretry = 3                   # failures allowed before a ban

[sshd]
enabled = true
# If you changed Port in configs/sshd_config, set port = <your port> here
# too, or bans on your real SSH port won't take effect.
```

## Quick setup script

`server-hardening.sh` is built for quick-applying to a fresh server, not
for customizing interactively. It does not ask for a port, does not ask
whether to disable password auth, and does not let you pick individual
services -- it just copies/overwrites the four files in `configs/` into
place, unmodified, for all four services in one run.

If you want different values, don't look for a prompt: **fork this repo
and edit the files under `configs/` directly.** The script always reads
from `configs/`, so your fork just works with your own settings.

SSH key generation happens on your local PC and cannot be scripted
remotely, so do step 2 manually first, confirm key login works, then run
the script for the rest -- `configs/sshd_config` ships with
`PasswordAuthentication no`, so running the script before key login works
can lock you out.

```bash
git clone https://codeberg.org/warden93/server-hardening.git
cd server-hardening
chmod +x server-hardening.sh
sudo ./server-hardening.sh
```

It prints a summary of what it's about to do (including the SSH port it
read out of `configs/sshd_config`) and asks for one confirmation before
making any changes. After that it runs straight through, with no further
prompts.

## Checklist

- [ ] Unattended upgrades installed and configured
- [ ] SSH key generated on local PC, copied to server
- [ ] Key login tested and working before disabling password auth
- [ ] PermitRootLogin no, PasswordAuthentication no set
- [ ] UFW enabled, correct SSH port allowed
- [ ] fail2ban installed and sshd jail active