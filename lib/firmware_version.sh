#!/bin/bash
# Parse the human-readable first line of /userdata/etc/version.
#
# The line is descriptive rather than machine-only, for example:
#   Lidl Zigbee Gateway RTL8196E - v4.0.0-rc5
#
# firmware_version_parse <line>
#   Sets FWPARSE_VERSION to the complete SemVer-like value without the leading
#   "v", and FWPARSE_MAJOR to its numeric major component.

firmware_version_parse() {
    local line="${1:-}"
    local version_re

    FWPARSE_VERSION=""
    FWPARSE_MAJOR=""

    # Keep prerelease/build suffixes intact. The boundaries prevent malformed
    # values such as v4.0.0_rc5 or dev4.0.0 from being accepted as v4.0.0.
    version_re='(^|[^0-9A-Za-z])v(([0-9]+)\.([0-9]+)\.([0-9]+)(-([0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*))?(\+([0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*))?)([^0-9A-Za-z_.+-]|$)'
    if [[ "$line" =~ $version_re ]]; then
        # Outputs consumed by the caller that sourced this library.
        # shellcheck disable=SC2034
        FWPARSE_VERSION="${BASH_REMATCH[2]}"
        # shellcheck disable=SC2034
        FWPARSE_MAJOR="${BASH_REMATCH[3]}"
        return 0
    fi

    return 1
}
