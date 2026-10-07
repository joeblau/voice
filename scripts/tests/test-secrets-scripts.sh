#!/bin/sh
# Tests for scripts/check-embedded-secrets.sh and scripts/write-secrets-xcconfig.sh.
# Hermetic: uses fake keys and a temporary directory. Run with `make test-scripts`.

set -u

scripts_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
check="$scripts_dir/check-embedded-secrets.sh"
write="$scripts_dir/write-secrets-xcconfig.sh"

work=$(mktemp -d "${TMPDIR:-/tmp}/blau-secrets-tests.XXXXXX")
trap 'rm -rf "$work"' EXIT

# Assembled at runtime so this file never contains a key-shaped literal.
fake_key="xai-$(printf 'A1b2C3d4%.0s' 1 2 3 4 5 6)"

passed=0
failed=0

pass() { passed=$((passed + 1)); echo "ok   - $1"; }
fail() { failed=$((failed + 1)); echo "FAIL - $1"; }

# expect <description> <expected exit status> <command...>
expect() {
    description=$1
    expected=$2
    shift 2
    "$@" >"$work/out" 2>&1
    actual=$?
    if [ "$actual" -eq "$expected" ]; then
        pass "$description"
    else
        fail "$description (exit $actual, expected $expected)"
        sed 's/^/       /' "$work/out"
    fi
}

clean_binary="$work/clean.bin"
dirty_binary="$work/dirty.bin"
printf 'xai-client-secret.\0https://api.x.ai\0grok-voice-think-fast-2.0\0' >"$clean_binary"
printf '\0\1\2junk%s\0more' "$fake_key" >"$dirty_binary"

# --- check-embedded-secrets.sh -------------------------------------------------

expect "debug: not enforced, dev key allowed" 0 \
    env BLAU_FORBID_EMBEDDED_SECRETS=NO XAI_DEV_API_KEY="$fake_key" "$check" "$dirty_binary"

expect "enforcement defaults to off" 0 \
    env -u BLAU_FORBID_EMBEDDED_SECRETS XAI_DEV_API_KEY="$fake_key" "$check"

expect "release: no key, clean files pass" 0 \
    env BLAU_FORBID_EMBEDDED_SECRETS=YES XAI_DEV_API_KEY= "$check" "$clean_binary"

expect "release: whitespace-only key counts as empty" 0 \
    env BLAU_FORBID_EMBEDDED_SECRETS=YES XAI_DEV_API_KEY="   " "$check" "$clean_binary"

expect "release: XAI_DEV_API_KEY set fails" 1 \
    env BLAU_FORBID_EMBEDDED_SECRETS=YES XAI_DEV_API_KEY="$fake_key" "$check" "$clean_binary"

expect "release: any non-empty XAI_DEV_API_KEY fails, not only xai- keys" 1 \
    env BLAU_FORBID_EMBEDDED_SECRETS=YES XAI_DEV_API_KEY="not-a-real-key" "$check"

expect "release: key embedded in binary fails" 1 \
    env BLAU_FORBID_EMBEDDED_SECRETS=YES XAI_DEV_API_KEY= "$check" "$clean_binary" "$dirty_binary"

expect "release: missing input file fails" 1 \
    env BLAU_FORBID_EMBEDDED_SECRETS=YES XAI_DEV_API_KEY= "$check" "$work/does-not-exist"

env BLAU_FORBID_EMBEDDED_SECRETS=YES XAI_DEV_API_KEY="$fake_key" "$check" "$dirty_binary" >"$work/out" 2>&1
if grep -q -F "$fake_key" "$work/out"; then
    fail "error output never contains the key"
else
    pass "error output never contains the key"
fi

# --- write-secrets-xcconfig.sh -------------------------------------------------

secrets="$work/Secrets.xcconfig"

expect "writer: writes key from environment" 0 env XAI_DEV_API_KEY="$fake_key" "$write" "$secrets"
if grep -q -x "XAI_DEV_API_KEY = $fake_key" "$secrets"; then
    pass "writer: file contains the key assignment"
else
    fail "writer: file contains the key assignment"
fi
if grep -q -F "$fake_key" "$work/out"; then
    fail "writer: output never contains the key"
else
    pass "writer: output never contains the key"
fi
case "$(ls -l "$secrets")" in
    -rw-------*) pass "writer: file is private (0600)" ;;
    *) fail "writer: file is private (0600)" ;;
esac

expect "writer: empty secret writes an empty key" 0 env XAI_DEV_API_KEY= "$write" "$secrets"
if grep -q -x "XAI_DEV_API_KEY = " "$secrets"; then
    pass "writer: empty key assignment"
else
    fail "writer: empty key assignment"
fi

expect "writer: rejects xcconfig comment sequence" 1 env XAI_DEV_API_KEY="abc//def" "$write" "$secrets"

rm -f "$secrets"
expect "writer: unset variable copies the example" 0 env -u XAI_DEV_API_KEY "$write" "$secrets"
if cmp -s "$secrets" "$scripts_dir/../Config/Secrets.example.xcconfig"; then
    pass "writer: copied file matches Secrets.example.xcconfig"
else
    fail "writer: copied file matches Secrets.example.xcconfig"
fi

echo "keep" >"$secrets"
expect "writer: unset variable keeps an existing file" 0 env -u XAI_DEV_API_KEY "$write" "$secrets"
if [ "$(cat "$secrets")" = "keep" ]; then
    pass "writer: existing file unchanged"
else
    fail "writer: existing file unchanged"
fi

# --- example file -------------------------------------------------------------

example="$scripts_dir/../Config/Secrets.example.xcconfig"
if grep -E -q '^XAI_DEV_API_KEY *= *$' "$example"; then
    pass "Secrets.example.xcconfig ships an empty key"
else
    fail "Secrets.example.xcconfig ships an empty key"
fi

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
