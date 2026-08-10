#!/bin/sh
# build_s40button.sh — Build STATIC s40button binary with Lexra toolchain.
#
# s40button: front-panel button daemon, polls the reset-button GPIO line
# (named in the board DTS, fallback line 9) through /dev/gpiochip0 and
# triggers recover_efr32 on a 5 s long-press.  Replaces the busybox shell
# loop that had an intermittent SIGSEGV in idle polling (v3.2.x/v3.3.0).
#
# See ../s40button/src/s40button.c for the full mechanism documentation.
#
# Usage:
#   ./build_s40button.sh
#
# J. Nilo - April 2026

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
USERDATA_PART="${SCRIPT_DIR}/.."
# Project root is 4 levels up: s40button -> 34-Userdata -> 3-Main-SoC -> project root
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

SOURCE_DIR="${SCRIPT_DIR}/src"
INSTALL_DIR="${USERDATA_PART}/skeleton/usr/sbin"

VERSION="2.1"

if [ ! -f "${SOURCE_DIR}/s40button.c" ]; then
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
echo "  BUILDING S40BUTTON v${VERSION}"
echo "========================================="
echo
echo "Compiler: ${CC}"
echo "CFLAGS:   ${CFLAGS}"
echo "LDFLAGS:  ${LDFLAGS}"
echo

cd "$SOURCE_DIR"

rm -f s40button

echo "==> Compiling s40button..."
$CC $CFLAGS $LDFLAGS \
    -o s40button \
    s40button.c

echo "==> Verifying binary..."
file s40button
${CROSS_COMPILE}readelf -d s40button 2>&1 | grep -q "no dynamic" && echo "==> Static binary confirmed"

echo "==> Stripping binary..."
$STRIP s40button

install -d "${INSTALL_DIR}"
cp -f s40button "${INSTALL_DIR}/"

echo
echo "========================================="
echo "  BUILD SUMMARY"
echo "========================================="
echo "  Version: ${VERSION}"
echo "  Binary:  $(ls -lh s40button | awk '{print $5}')"
echo "  Install: ${INSTALL_DIR}/s40button"
echo
echo "==> s40button v${VERSION} static (musl/MIPS) installed in ${INSTALL_DIR}"
