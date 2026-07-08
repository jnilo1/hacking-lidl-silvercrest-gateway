#!/bin/sh
# build_otbr-monitor.sh — Build STATIC otbr-monitor binary with Lexra toolchain.
#
# otbr-monitor: OTBR housekeeping daemon (radio tuning, status LED, dataset
# sync, one-shot SRP recovery), supervised by keepalive from S70otbr. This is
# the C rewrite of the former busybox-ash monitor loop — the last long-lived
# ash loop in the system and the only process still exposed to the RLX4181
# intermittent SIGSEGV/SIGILL/SIGBUS fault (issue #109). A long-lived C process
# never runs ash, so it cannot hit that fault.
#
# See ./src/otbr-monitor.c for the full behaviour documentation.
#
# Usage:
#   ./build_otbr-monitor.sh
#
# J. Nilo - July 2026

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
USERDATA_PART="${SCRIPT_DIR}/.."
# Project root is 4 levels up: otbr-monitor -> 34-Userdata -> 3-Main-SoC -> project root
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

SOURCE_DIR="${SCRIPT_DIR}/src"
INSTALL_DIR="${USERDATA_PART}/skeleton/usr/sbin"

VERSION="1.0"

if [ ! -f "${SOURCE_DIR}/otbr-monitor.c" ]; then
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
echo "  BUILDING OTBR-MONITOR v${VERSION}"
echo "========================================="
echo
echo "Compiler: ${CC}"
echo "CFLAGS:   ${CFLAGS}"
echo "LDFLAGS:  ${LDFLAGS}"
echo

cd "$SOURCE_DIR"

rm -f otbr-monitor

echo "==> Compiling otbr-monitor..."
$CC $CFLAGS $LDFLAGS \
    -o otbr-monitor \
    otbr-monitor.c

echo "==> Verifying binary..."
file otbr-monitor
${CROSS_COMPILE}readelf -d otbr-monitor 2>&1 | grep -q "no dynamic" && echo "==> Static binary confirmed"

echo "==> Stripping binary..."
$STRIP otbr-monitor

install -d "${INSTALL_DIR}"
cp -f otbr-monitor "${INSTALL_DIR}/"

echo
echo "========================================="
echo "  BUILD SUMMARY"
echo "========================================="
echo "  Version: ${VERSION}"
echo "  Binary:  $(ls -lh otbr-monitor | awk '{print $5}')"
echo "  Install: ${INSTALL_DIR}/otbr-monitor"
echo
echo "==> otbr-monitor v${VERSION} static (musl/MIPS) installed in ${INSTALL_DIR}"
