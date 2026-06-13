#!/bin/sh
# build_linkwatch.sh — Build STATIC linkwatch binary with Lexra toolchain.
#
# linkwatch: re-triggers DHCP on link-up. Polls /sys/class/net/<iface>/carrier
# and, on a 0->1 transition, pokes udhcpc (SIGUSR2 release + SIGUSR1 discover)
# so the gateway re-acquires a lease after being moved to a different subnet
# (issue #132). Started by S10network in the DHCP branch only. C, like
# keepalive / s40button, so a long-lived poll loop never runs busybox ash
# (issue #109 fault class).
#
# See ./src/linkwatch.c for the full mechanism documentation.
#
# Usage:
#   ./build_linkwatch.sh
#
# J. Nilo - June 2026

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
USERDATA_PART="${SCRIPT_DIR}/.."
# Project root is 4 levels up: linkwatch -> 34-Userdata -> 3-Main-SoC -> project root
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

SOURCE_DIR="${SCRIPT_DIR}/src"
INSTALL_DIR="${USERDATA_PART}/skeleton/usr/sbin"

VERSION="1.0"

if [ ! -f "${SOURCE_DIR}/linkwatch.c" ]; then
    echo "Error: source file not found in ${SOURCE_DIR}"
    exit 1
fi

# Lexra toolchain (musl 1.2.6)
TOOLCHAIN_DIR="${PROJECT_ROOT}/x-tools/mips-lexra-linux-musl"
if ! command -v mips-lexra-linux-musl-gcc >/dev/null 2>&1; then
    export PATH="${TOOLCHAIN_DIR}/bin:$PATH"
fi
export CROSS_COMPILE="mips-lexra-linux-musl-"

CC="${CROSS_COMPILE}gcc"
STRIP="${CROSS_COMPILE}strip"
CFLAGS="-Os -fno-stack-protector -Wall -Wextra"
LDFLAGS="-static -Wl,-z,noexecstack,-z,relro,-z,now"

echo "========================================="
echo "  BUILDING LINKWATCH v${VERSION}"
echo "========================================="
echo
echo "Compiler: ${CC}"
echo "CFLAGS:   ${CFLAGS}"
echo "LDFLAGS:  ${LDFLAGS}"
echo

cd "$SOURCE_DIR"

rm -f linkwatch

echo "==> Compiling linkwatch..."
$CC $CFLAGS $LDFLAGS \
    -o linkwatch \
    linkwatch.c

echo "==> Verifying binary..."
file linkwatch
${CROSS_COMPILE}readelf -d linkwatch 2>&1 | grep -q "no dynamic" && echo "==> Static binary confirmed"

echo "==> Stripping binary..."
$STRIP linkwatch

install -d "${INSTALL_DIR}"
cp -f linkwatch "${INSTALL_DIR}/"

echo
echo "========================================="
echo "  BUILD SUMMARY"
echo "========================================="
echo "  Version: ${VERSION}"
echo "  Binary:  $(ls -lh linkwatch | awk '{print $5}')"
echo "  Install: ${INSTALL_DIR}/linkwatch"
echo
echo "==> linkwatch v${VERSION} static (musl/MIPS) installed in ${INSTALL_DIR}"
