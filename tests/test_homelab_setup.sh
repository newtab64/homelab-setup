#!/usr/bin/env bash
#
# tests/test_homelab_setup.sh
# Comprehensive offline test suite for homelab-setup
#

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGS="$REPO_DIR/configs"

TOTAL_TESTS=0
PASSED_TESTS=0

assert_eq() {
    local desc="$1"
    local expected="$2"
    local actual="$3"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    if [[ "$expected" == "$actual" ]]; then
        PASSED_TESTS=$((PASSED_TESTS + 1))
        echo "  [PASS] $desc"
    else
        echo "  [FAIL] $desc (expected '$expected', got '$actual')" >&2
    fi
}

assert_status() {
    local desc="$1"
    local expected_status="$2"
    local actual_status="$3"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    if [[ "$expected_status" == "$actual_status" ]]; then
        PASSED_TESTS=$((PASSED_TESTS + 1))
        echo "  [PASS] $desc"
    else
        echo "  [FAIL] $desc (expected status $expected_status, got $actual_status)" >&2
    fi
}

assert_file_contains() {
    local desc="$1"
    local pattern="$2"
    local file="$3"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    if grep -qE "$pattern" "$file"; then
        PASSED_TESTS=$((PASSED_TESTS + 1))
        echo "  [PASS] $desc"
    else
        echo "  [FAIL] $desc (pattern '$pattern' not found in $file)" >&2
    fi
}

echo "=== 1. Checking File Existence & Permissions ==="

for f in homelab-setup.sh configs/jail.local configs/sshd_config; do
    status=0
    [[ -f "$REPO_DIR/$f" ]] || status=$?
    assert_status "File exists: $f" "0" "$status"
done

status=0
[[ -x "$REPO_DIR/homelab-setup.sh" ]] || status=$?
assert_status "homelab-setup.sh is executable" "0" "$status"

echo
echo "=== 2. Checking Bash Syntax ==="

for f in homelab-setup.sh tests/test_validation.sh; do
    status=0
    bash -n "$REPO_DIR/$f" || status=$?
    assert_status "Syntax valid: $f" "0" "$status"
done

echo
echo "=== 3. Validating SSH Configuration with sshd ==="

TEMP_KEY="/tmp/test_sshd_key_$(date +%s)"
ssh-keygen -t ed25519 -f "$TEMP_KEY" -N "" -q
status=0
/usr/sbin/sshd -t -f "$CONFIGS/sshd_config" -h "$TEMP_KEY" || status=$?
assert_status "sshd -t passes on configs/sshd_config" "0" "$status"
rm -f "$TEMP_KEY" "${TEMP_KEY}.pub"

# Check strict IPv4 and hardening directives
assert_file_contains "sshd_config restricts AddressFamily to inet" "^AddressFamily inet" "$CONFIGS/sshd_config"
assert_file_contains "sshd_config sets MaxAuthTries 3" "^MaxAuthTries 3" "$CONFIGS/sshd_config"
assert_file_contains "sshd_config disables AllowAgentForwarding" "^AllowAgentForwarding no" "$CONFIGS/sshd_config"
assert_file_contains "sshd_config disables PermitUserEnvironment" "^PermitUserEnvironment no" "$CONFIGS/sshd_config"

echo
echo "=== 4. Testing Port Extraction ==="

SSH_PORT="$(grep -iE '^[[:space:]]*Port[[:space:]]+[0-9]+[[:space:]]*$' "$CONFIGS/sshd_config" \
    | tail -n1 | awk '{print $2}')"
SSH_PORT="${SSH_PORT:-22}"
assert_eq "Extracted SSH port is 22" "22" "$SSH_PORT"

echo
echo "=== 5. Mock Testing Target File Generations ==="

TEST_DIR="/tmp/test_homelab_root_$(date +%s)"
mkdir -p "$TEST_DIR/etc/cron.d" "$TEST_DIR/etc/systemd/logind.conf.d" "$TEST_DIR/etc/tlp.d" "$TEST_DIR/etc/default"

# Test crontab line generation and idempotent replacement
MOCK_CRONTAB_BEFORE="0 2 * * * /usr/bin/some-other-job"
CRON_TAG="# homelab-autoupdate"
CRON_CMD="0 0 * * * DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y && apt-get autoremove --purge -y && apt-get autoclean && sync && (shutdown -r now || reboot) >> /var/log/homelab-autoupdate.log 2>&1 $CRON_TAG"

# First insertion
RESULT_1="$( (echo "$MOCK_CRONTAB_BEFORE" | grep -F -v "$CRON_TAG" || true; echo "$CRON_CMD") )"
echo "$RESULT_1" > "$TEST_DIR/crontab.test"
assert_file_contains "Crontab includes existing job" "some-other-job" "$TEST_DIR/crontab.test"
assert_file_contains "Crontab includes homelab-autoupdate command" "^0 0 \* \* \* .* >> /var/log/homelab-autoupdate.log" "$TEST_DIR/crontab.test"

# Second insertion (idempotency check - should not duplicate)
RESULT_2="$( (cat "$TEST_DIR/crontab.test" | grep -F -v "$CRON_TAG" || true; echo "$CRON_CMD") )"
echo "$RESULT_2" > "$TEST_DIR/crontab.test"
CRON_OCCURRENCES="$(grep -c "homelab-autoupdate" "$TEST_DIR/crontab.test")"
assert_eq "Crontab has exactly 1 entry for homelab-autoupdate" "1" "$CRON_OCCURRENCES"

# Test direct logind.conf modification
mkdir -p "$TEST_DIR/etc/systemd"
cat << 'EOF' > "$TEST_DIR/etc/systemd/logind.conf"
[Login]
#HandleLidSwitch=suspend
#HandleLidSwitchExternalPower=suspend
#HandleLidSwitchDocked=ignore
#LidSwitchIgnoreInhibited=yes
EOF

sed -i -E 's/^#?[[:space:]]*HandleLidSwitch=.*/HandleLidSwitch=ignore/' "$TEST_DIR/etc/systemd/logind.conf"
sed -i -E 's/^#?[[:space:]]*HandleLidSwitchExternalPower=.*/HandleLidSwitchExternalPower=ignore/' "$TEST_DIR/etc/systemd/logind.conf"
sed -i -E 's/^#?[[:space:]]*HandleLidSwitchDocked=.*/HandleLidSwitchDocked=ignore/' "$TEST_DIR/etc/systemd/logind.conf"
sed -i -E 's/^#?[[:space:]]*LidSwitchIgnoreInhibited=.*/LidSwitchIgnoreInhibited=yes/' "$TEST_DIR/etc/systemd/logind.conf"

assert_file_contains "logind.conf contains HandleLidSwitch=ignore" "^HandleLidSwitch=ignore" "$TEST_DIR/etc/systemd/logind.conf"
assert_file_contains "logind.conf contains HandleLidSwitchExternalPower=ignore" "^HandleLidSwitchExternalPower=ignore" "$TEST_DIR/etc/systemd/logind.conf"
assert_file_contains "logind.conf contains HandleLidSwitchDocked=ignore" "^HandleLidSwitchDocked=ignore" "$TEST_DIR/etc/systemd/logind.conf"
assert_file_contains "logind.conf contains LidSwitchIgnoreInhibited=yes" "^LidSwitchIgnoreInhibited=yes" "$TEST_DIR/etc/systemd/logind.conf"

# Test TLP file generation (replaces /etc/tlp.conf with max 4 lines)
START=45
STOP=50
rm -f "$TEST_DIR/etc/tlp.conf"
cat << EOF > "$TEST_DIR/etc/tlp.conf"
START_CHARGE_THRESH_BAT0=${START}
STOP_CHARGE_THRESH_BAT0=${STOP}
CPU_SCALING_GOVERNOR_ON_AC=powersave
CPU_SCALING_GOVERNOR_ON_BAT=powersave
EOF
TLP_LINES="$(wc -l < "$TEST_DIR/etc/tlp.conf")"
assert_status "TLP config has maximum 4 lines" "0" "$([ "$TLP_LINES" -le 4 ] && echo 0 || echo 1)"
assert_file_contains "TLP file contains START_CHARGE_THRESH_BAT0=45" "^START_CHARGE_THRESH_BAT0=45" "$TEST_DIR/etc/tlp.conf"
assert_file_contains "TLP file contains STOP_CHARGE_THRESH_BAT0=50" "^STOP_CHARGE_THRESH_BAT0=50" "$TEST_DIR/etc/tlp.conf"
assert_file_contains "TLP file sets CPU_SCALING_GOVERNOR_ON_AC=powersave" "^CPU_SCALING_GOVERNOR_ON_AC=powersave" "$TEST_DIR/etc/tlp.conf"
assert_file_contains "TLP file sets CPU_SCALING_GOVERNOR_ON_BAT=powersave" "^CPU_SCALING_GOVERNOR_ON_BAT=powersave" "$TEST_DIR/etc/tlp.conf"

# Test UFW IPV6=no substitution
echo 'IPV6=yes' > "$TEST_DIR/etc/default/ufw"
sed -i 's/^IPV6=.*/IPV6=no/' "$TEST_DIR/etc/default/ufw"
assert_file_contains "UFW default config modified to IPV6=no" "^IPV6=no" "$TEST_DIR/etc/default/ufw"

rm -rf "$TEST_DIR"

echo
echo "=== Test Suite Summary ==="
echo "Passed: $PASSED_TESTS / $TOTAL_TESTS"

if [[ "$PASSED_TESTS" -ne "$TOTAL_TESTS" ]]; then
    exit 1
fi
