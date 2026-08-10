#!/bin/sh
# build_netwatch.sh — Build STATIC netwatch binary with Lexra toolchain.
#
# netwatch: reboots — and above all records — a gateway that has gone silent
# while its link carrier is still up. The hardware watchdog only catches a
# stopped CPU; a board whose userspace is alive but whose network path is dead
# keeps feeding it and simply disappears from the LAN until someone power-
# cycles it, which destroys the reset-reason latch and the reserved-DRAM panic
# record along with it. netwatch writes a snapshot to /userdata (JFFS2, so it
# survives the power cycle) before rebooting through the clean init path.
#
# See ./src/netwatch.c for the full mechanism documentation, in particular why
# the carrier must be up before acting and why the reboot must not use
# reboot(2).
#
# Usage:
#   ./build_netwatch.sh
#
# J. Nilo - July 2026

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
USERDATA_PART="${SCRIPT_DIR}/.."
# Project root is 4 levels up: netwatch -> 34-Userdata -> 3-Main-SoC -> project root
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

SOURCE_DIR="${SCRIPT_DIR}/src"
INSTALL_DIR="${USERDATA_PART}/skeleton/usr/sbin"

VERSION="1.0"

if [ ! -f "${SOURCE_DIR}/netwatch.c" ]; then
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
echo "  BUILDING NETWATCH v${VERSION}"
echo "========================================="
echo
echo "Compiler: ${CC}"
echo "CFLAGS:   ${CFLAGS}"
echo "LDFLAGS:  ${LDFLAGS}"
echo

cd "$SOURCE_DIR"

rm -f netwatch

echo "==> Compiling netwatch..."
$CC $CFLAGS $LDFLAGS \
    -o netwatch \
    netwatch.c

echo "==> Verifying binary..."
file netwatch
${CROSS_COMPILE}readelf -d netwatch 2>&1 | grep -q "no dynamic" && echo "==> Static binary confirmed"

echo "==> Stripping binary..."
$STRIP netwatch

install -d "${INSTALL_DIR}"
cp -f netwatch "${INSTALL_DIR}/"

echo
echo "========================================="
echo "  BUILD SUMMARY"
echo "========================================="
echo "  Version: ${VERSION}"
echo "  Binary:  $(ls -lh netwatch | awk '{print $5}')"
echo "  Install: ${INSTALL_DIR}/netwatch"
echo
echo "==> netwatch v${VERSION} static (musl/MIPS) installed in ${INSTALL_DIR}"
