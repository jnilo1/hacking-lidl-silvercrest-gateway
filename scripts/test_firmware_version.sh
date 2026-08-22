#!/bin/bash
# Non-destructive regression tests for lib/firmware_version.sh.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "${REPO}/lib/firmware_version.sh"

PASS=0
FAIL=0

check_valid() { # label, input, expected version, expected major
    local label="$1" input="$2" want_version="$3" want_major="$4"

    if firmware_version_parse "$input" \
       && [ "$FWPARSE_VERSION" = "$want_version" ] \
       && [ "$FWPARSE_MAJOR" = "$want_major" ]; then
        PASS=$((PASS + 1))
        printf '  ok   %s -> %s (major %s)\n' "$label" "$FWPARSE_VERSION" "$FWPARSE_MAJOR"
    else
        FAIL=$((FAIL + 1))
        printf '  FAIL %s -> version=[%s] major=[%s], want [%s]/[%s]\n' \
            "$label" "$FWPARSE_VERSION" "$FWPARSE_MAJOR" "$want_version" "$want_major"
    fi
}

check_invalid() { # label, input
    local label="$1" input="$2"

    if firmware_version_parse "$input"; then
        FAIL=$((FAIL + 1))
        printf '  FAIL %s unexpectedly parsed as [%s]\n' "$label" "$FWPARSE_VERSION"
    elif [ -n "$FWPARSE_VERSION" ] || [ -n "$FWPARSE_MAJOR" ]; then
        FAIL=$((FAIL + 1))
        printf '  FAIL %s left stale output version=[%s] major=[%s]\n' \
            "$label" "$FWPARSE_VERSION" "$FWPARSE_MAJOR"
    else
        PASS=$((PASS + 1))
        printf '  ok   %s rejected\n' "$label"
    fi
}

check_valid "release" \
    "Lidl Zigbee Gateway RTL8196E - v4.0.0" "4.0.0" "4"
check_valid "release candidate from issue #156" \
    "Lidl Zigbee Gateway RTL8196E - v4.0.0-rc5" "4.0.0-rc5" "4"
check_valid "historical prerelease" \
    "Lidl Zigbee Gateway RTL8196E - v4.0.0-pre" "4.0.0-pre" "4"
check_valid "prerelease and build metadata" \
    "firmware v4.2.0-rc.1+bench.7 ready" "4.2.0-rc.1+bench.7" "4"
check_valid "v2 migration input" \
    "Lidl Zigbee Gateway RTL8196E - v2.9.0-rc1" "2.9.0-rc1" "2"

check_invalid "missing patch component" "firmware v4.0"
check_invalid "empty prerelease" "firmware v4.0.0-"
check_invalid "underscore suffix" "firmware v4.0.0_rc5"
check_invalid "embedded version token" "firmware dev4.0.0"
check_invalid "no version" "Lidl Zigbee Gateway RTL8196E"

printf '\npassed=%d failed=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
