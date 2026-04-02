#!/bin/sh
# build_serialgateway.sh — Build STATIC serialgateway with Lexra toolchain (musl 1.2.5) for RTL8196E
#
# serialgateway: TCP-to-serial bridge for Zigbee module on /dev/ttyS1
# Original source: https://github.com/banksy-git/lidl-gateway-freedom/tree/master/gateway
# Original author: Paul Banks
# License: GPL-3.0
#
# Local revision (v2.0) improvements:
#   - Fixed buffer type (int -> uint8_t) - memory optimization
#   - Added TCP_NODELAY for lower latency (important for EZSP)
#   - Added -h help, -v version, -q quiet mode
#   - Validated port range and baud rate
#   - Added daemon mode (default), -D for foreground
#
# Usage:
#   ./build_serialgateway.sh
#
# J. Nilo - Dec 2025

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
USERDATA_PART="${SCRIPT_DIR}/.."
# Project root is 4 levels up: serialgateway -> 34-Userdata -> 3-Main-SoC -> project root
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

SOURCE_DIR="${SCRIPT_DIR}/src"
INSTALL_DIR="${USERDATA_PART}/skeleton/usr/bin"

# Version info - local revision
VERSION="2.2"

# Check if sources exist (local revised version)
if [ ! -f "${SOURCE_DIR}/main.c" ]; then
    echo "Error: source files not found in ${SOURCE_DIR}"
    echo "The revised source code should be in the repository."
    exit 1
fi

# Lexra toolchain (musl 1.2.5)
TOOLCHAIN_DIR="${PROJECT_ROOT}/x-tools/mips-lexra-linux-musl"
if ! command -v mips-lexra-linux-musl-gcc >/dev/null 2>&1; then
    export PATH="${TOOLCHAIN_DIR}/bin:$PATH"
fi
export CROSS_COMPILE="mips-lexra-linux-musl-"

# Compiler settings
CC="${CROSS_COMPILE}gcc"
STRIP="${CROSS_COMPILE}strip"
CFLAGS="-Os -fno-stack-protector -Wall"
LDFLAGS="-static -Wl,-z,noexecstack,-z,relro,-z,now"

echo "========================================="
echo "  BUILDING SERIALGATEWAY v${VERSION}"
echo "========================================="
echo ""
echo "Compiler: ${CC}"
echo "CFLAGS:   ${CFLAGS}"
echo "LDFLAGS:  ${LDFLAGS}"
echo ""

cd "$SOURCE_DIR"

# Clean previous build
rm -f serialgateway

echo "==> Compiling serialgateway..."
$CC $CFLAGS $LDFLAGS \
    -DVERSION=\"${VERSION}\" \
    -o serialgateway \
    main.c serial.c

echo "==> Verifying binary..."
file serialgateway
${CROSS_COMPILE}readelf -d serialgateway 2>&1 | grep -q "no dynamic" && echo "==> Static binary confirmed"

# Strip and install
echo "==> Stripping binary..."
$STRIP serialgateway

install -d "${INSTALL_DIR}"
cp -f serialgateway "${INSTALL_DIR}/"

echo ""
echo "========================================="
echo "  BUILD SUMMARY"
echo "========================================="
echo "  Version: ${VERSION}"
echo "  Binary:  $(ls -lh serialgateway | awk '{print $5}')"
echo "  Install: ${INSTALL_DIR}/serialgateway"
echo ""
echo "==> serialgateway v${VERSION} static (musl/MIPS) installed in ${INSTALL_DIR}"
