#!/bin/sh
# build_boothold.sh — Build STATIC boothold binary with Lexra toolchain for RTL8196E
#
# boothold: write HOLD magic to DRAM (with cache flush) and reboot into
# the <RealTek> bootloader prompt.  Replaces the shell script version
# which used devmem (writes through KSEG0 write-back cache — unreliable,
# the cache line may not reach DRAM before the watchdog reset).
#
# Usage:
#   ./build_boothold.sh
#
# J. Nilo - March 2026

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
USERDATA_PART="${SCRIPT_DIR}/.."
# Project root is 4 levels up: boothold -> 34-Userdata -> 3-Main-SoC -> project root
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

SOURCE_DIR="${SCRIPT_DIR}/src"
INSTALL_DIR="${USERDATA_PART}/skeleton/usr/bin"

VERSION="1.0"

# Check if source exists
if [ ! -f "${SOURCE_DIR}/boothold.c" ]; then
    echo "Error: source file not found in ${SOURCE_DIR}"
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
echo "  BUILDING BOOTHOLD v${VERSION}"
echo "========================================="
echo ""
echo "Compiler: ${CC}"
echo "CFLAGS:   ${CFLAGS}"
echo "LDFLAGS:  ${LDFLAGS}"
echo ""

cd "$SOURCE_DIR"

# Clean previous build
rm -f boothold

echo "==> Compiling boothold..."
$CC $CFLAGS $LDFLAGS \
    -o boothold \
    boothold.c

echo "==> Verifying binary..."
file boothold
${CROSS_COMPILE}readelf -d boothold 2>&1 | grep -q "no dynamic" && echo "==> Static binary confirmed"

# Strip and install
echo "==> Stripping binary..."
$STRIP boothold

install -d "${INSTALL_DIR}"
cp -f boothold "${INSTALL_DIR}/"

echo ""
echo "========================================="
echo "  BUILD SUMMARY"
echo "========================================="
echo "  Version: ${VERSION}"
echo "  Binary:  $(ls -lh boothold | awk '{print $5}')"
echo "  Install: ${INSTALL_DIR}/boothold"
echo ""
echo "==> boothold v${VERSION} static (musl/MIPS) installed in ${INSTALL_DIR}"
