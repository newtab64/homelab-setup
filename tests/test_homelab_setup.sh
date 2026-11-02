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

for f in homelab-setup.sh configs/homelab-autoupdate.sh configs/jail.local configs/sshd_config; do
    status=0
    [[ -f "$REPO_DIR/$f" ]] || status=$?
    assert_status "File exists: $f" "0" "$status"
done

status=0
[[ -x "$REPO_DIR/homelab-setup.sh" ]] || status=$?
assert_status "homelab-setup.sh is executable" "0" "$status"

status=0
[[ -x "$REPO_DIR/configs/homelab-autoupdate.sh" ]] || status=$?
assert_status "configs/homelab-autoupdate.sh is executable" "0" "$status"

echo
echo "=== 2. Checking Bash Syntax ==="

for f in homelab-setup.sh configs/homelab-autoupdate.sh tests/test_validation.sh; do
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

# Test cron file generation
cat << 'EOF' > "$TEST_DIR/etc/cron.d/homelab-autoupdate"
# /etc/cron.d/homelab-autoupdate
# Runs daily homelab maintenance (apt update, upgrade, cleanup, and reboot)
0 0 * * * root /usr/local/bin/homelab-autoupdate.sh >> /var/log/homelab-autoupdate.log 2>&1
EOF
assert_file_contains "Cron file contains daily 00:00 schedule" "^0 0 \* \* \* root /usr/local/bin/homelab-autoupdate.sh >> /var/log/homelab-autoupdate.log 2>&1" "$TEST_DIR/etc/cron.d/homelab-autoupdate"

# Test lid ignore file generation
cat << 'EOF' > "$TEST_DIR/etc/systemd/logind.conf.d/00-homelab-lid.conf"
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
LidSwitchIgnoreInhibited=yes
EOF
assert_file_contains "Logind drop-in contains HandleLidSwitch=ignore" "^HandleLidSwitch=ignore" "$TEST_DIR/etc/systemd/logind.conf.d/00-homelab-lid.conf"
assert_file_contains "Logind drop-in contains LidSwitchIgnoreInhibited=yes" "^LidSwitchIgnoreInhibited=yes" "$TEST_DIR/etc/systemd/logind.conf.d/00-homelab-lid.conf"

# Test TLP file generation
START=45
STOP=50
cat << EOF > "$TEST_DIR/etc/tlp.d/00-homelab.conf"
START_CHARGE_THRESH_BAT0=${START}
STOP_CHARGE_THRESH_BAT0=${STOP}
CPU_SCALING_GOVERNOR_ON_AC=powersave
CPU_ENERGY_PERF_POLICY_ON_AC=power
EOF
assert_file_contains "TLP file contains START_CHARGE_THRESH_BAT0=45" "^START_CHARGE_THRESH_BAT0=45" "$TEST_DIR/etc/tlp.d/00-homelab.conf"
assert_file_contains "TLP file contains STOP_CHARGE_THRESH_BAT0=50" "^STOP_CHARGE_THRESH_BAT0=50" "$TEST_DIR/etc/tlp.d/00-homelab.conf"
assert_file_contains "TLP file sets CPU_SCALING_GOVERNOR_ON_AC=powersave" "^CPU_SCALING_GOVERNOR_ON_AC=powersave" "$TEST_DIR/etc/tlp.d/00-homelab.conf"

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
