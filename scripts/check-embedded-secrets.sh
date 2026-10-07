#!/bin/sh
# check-embedded-secrets.sh: fail a build that would ship a raw xAI API key.
#
# Runs as the "Check for embedded secrets" post-build phase of the Blau target
# (see project.yml). It only enforces when BLAU_FORBID_EMBEDDED_SECRETS=YES,
# which Config/Release.xcconfig sets and Secrets.xcconfig cannot override.
#
# Checks:
#   1. XAI_DEV_API_KEY (normally from Config/Secrets.xcconfig) must be empty.
#   2. No file passed as an argument (the built executable and Info.plist) may
#      contain something that looks like an xAI API key ("xai-" followed by 20
#      or more letters/digits). This catches keys hard-coded in Swift sources
#      or plist values, not just the xcconfig variable.
#
# The key itself is never printed: messages show only its length and the file
# it was found in.
#
# Usage: check-embedded-secrets.sh [file ...]
# Environment: BLAU_FORBID_EMBEDDED_SECRETS, XAI_DEV_API_KEY, CONFIGURATION

set -eu

if [ "${BLAU_FORBID_EMBEDDED_SECRETS:-NO}" != "YES" ]; then
    exit 0
fi

configuration="${CONFIGURATION:-this}"
key_pattern='xai-[A-Za-z0-9]{20,}'
status=0

dev_key=$(printf '%s' "${XAI_DEV_API_KEY:-}" | tr -d '[:space:]')
if [ -n "$dev_key" ]; then
    echo "error: XAI_DEV_API_KEY is set (${#dev_key} characters) for the ${configuration} configuration." \
        "Release builds must not carry a developer API key. Empty XAI_DEV_API_KEY in" \
        "Config/Secrets.xcconfig (or pass XAI_DEV_API_KEY= to xcodebuild) and build again." >&2
    status=1
fi

for file in "$@"; do
    if [ ! -f "$file" ]; then
        echo "error: check-embedded-secrets: cannot scan missing file: $file" >&2
        status=1
        continue
    fi
    # -a: treat binaries as text. -E: extended regex. -q: never echo the match.
    if LC_ALL=C grep -a -E -q -e "$key_pattern" "$file"; then
        echo "error: $file contains a string that looks like an xAI API key (xai-...)." \
            "Remove the hard-coded key; the app reads the user's key from the Keychain." >&2
        status=1
    fi
done

if [ "$status" -eq 0 ]; then
    echo "check-embedded-secrets: no embedded xAI API keys found (${configuration})."
fi
exit "$status"
