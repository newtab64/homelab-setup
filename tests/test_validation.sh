#!/usr/bin/env bash
#
# tests/test_validation.sh
# Unit tests for input validation logic used in homelab-setup.sh
#

set -euo pipefail

# --- Functions under test ---

validate_yn() {
    local input="${1:-}"
    local default="${2:-n}"
    
    # If empty, use default
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
    
    # Check if purely numeric
    if [[ ! "$input" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    
    # Remove leading zeros unless it's just '0'
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

# --- Test runner ---

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

echo "=== Running Validation Tests ==="

# 1. validate_yn tests
echo "Testing validate_yn..."
out="$(validate_yn "" "y")" || status=$?
status=${status:-0}
assert_eq "Empty input with default 'y' outputs 'y'" "y" "$out"
assert_status "Empty input with default 'y' returns 0" "0" "$status"
unset status

status=0
out="$(validate_yn "" "n")" || status=$?
assert_eq "Empty input with default 'n' outputs 'n'" "n" "$out"
assert_status "Empty input with default 'n' returns 1" "1" "$status"

status=0
out="$(validate_yn "yes" "n")" || status=$?
assert_eq "'yes' outputs 'y'" "y" "$out"
assert_status "'yes' returns 0" "0" "$status"

status=0
out="$(validate_yn "NO" "y")" || status=$?
assert_eq "'NO' outputs 'n'" "n" "$out"
assert_status "'NO' returns 1" "1" "$status"

status=0
validate_yn "invalid" "y" >/dev/null 2>&1 || status=$?
assert_status "'invalid' returns 2" "2" "$status"

# 2. validate_threshold tests
echo "Testing validate_threshold..."
status=0
out="$(validate_threshold "" "45" 0 100)" || status=$?
assert_eq "Empty input with default 45 outputs 45" "45" "$out"
assert_status "Empty input with default 45 returns 0" "0" "$status"

status=0
out="$(validate_threshold "50" "45" 0 100)" || status=$?
assert_eq "Valid input '50' outputs 50" "50" "$out"
assert_status "Valid input '50' returns 0" "0" "$status"

status=0
out="$(validate_threshold "0" "45" 0 100)" || status=$?
assert_eq "Valid min '0' outputs 0" "0" "$out"
assert_status "Valid min '0' returns 0" "0" "$status"

status=0
out="$(validate_threshold "100" "45" 0 100)" || status=$?
assert_eq "Valid max '100' outputs 100" "100" "$out"
assert_status "Valid max '100' returns 0" "0" "$status"

status=0
validate_threshold "abc" "45" 0 100 >/dev/null 2>&1 || status=$?
assert_status "Non-numeric 'abc' returns 1" "1" "$status"

status=0
validate_threshold "45%" "45" 0 100 >/dev/null 2>&1 || status=$?
assert_status "Non-numeric '45%' returns 1" "1" "$status"

status=0
validate_threshold "-5" "45" 0 100 >/dev/null 2>&1 || status=$?
assert_status "Negative '-5' returns 1" "1" "$status"

status=0
validate_threshold "105" "45" 0 100 >/dev/null 2>&1 || status=$?
assert_status "Above max '105' returns 1" "1" "$status"

status=0
validate_threshold "5" "45" 10 100 >/dev/null 2>&1 || status=$?
assert_status "Below custom min '5' (min 10) returns 1" "1" "$status"

# 3. validate_threshold_pair tests
echo "Testing validate_threshold_pair..."
status=0
validate_threshold_pair 45 50 || status=$?
assert_status "Valid pair 45/50 returns 0" "0" "$status"

status=0
validate_threshold_pair 50 50 || status=$?
assert_status "Equal pair 50/50 returns 1" "1" "$status"

status=0
validate_threshold_pair 50 45 || status=$?
assert_status "Inverted pair 50/45 returns 1" "1" "$status"

echo
echo "Results: $PASSED_TESTS / $TOTAL_TESTS passed."
if [[ "$PASSED_TESTS" -ne "$TOTAL_TESTS" ]]; then
    exit 1
fi
