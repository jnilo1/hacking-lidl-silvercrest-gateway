#!/bin/sh
# build_keepalive.sh — Build STATIC keepalive binary with Lexra toolchain.
#
# keepalive: minimal process supervisor. Runs one child, restarts it with
# backoff on exit, forwards SIGTERM/SIGINT for clean stop. Used by S70otbr to
# supervise otbr-agent and the otbr-monitor housekeeping loop, so neither a
# crashed agent leaves OTBR down. Written when a busybox-ash SIGSEGV in the
# monitor was the other way it could happen (issue #109 — since root-caused to
# our own TLB flush and fixed); C still fits a supervisor that forks nothing.
#
# See ./src/keepalive.c for the full mechanism documentation.
#
# Usage:
#   ./build_keepalive.sh
#
# J. Nilo - May 2026

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
USERDATA_PART="${SCRIPT_DIR}/.."
# Project root is 4 levels up: keepalive -> 34-Userdata -> 3-Main-SoC -> project root
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

SOURCE_DIR="${SCRIPT_DIR}/src"
INSTALL_DIR="${USERDATA_PART}/skeleton/usr/sbin"

VERSION="1.0"

if [ ! -f "${SOURCE_DIR}/keepalive.c" ]; then
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
echo "  BUILDING KEEPALIVE v${VERSION}"
echo "========================================="
echo
echo "Compiler: ${CC}"
echo "CFLAGS:   ${CFLAGS}"
echo "LDFLAGS:  ${LDFLAGS}"
echo

cd "$SOURCE_DIR"

rm -f keepalive

echo "==> Compiling keepalive..."
$CC $CFLAGS $LDFLAGS \
    -o keepalive \
    keepalive.c

echo "==> Verifying binary..."
file keepalive
${CROSS_COMPILE}readelf -d keepalive 2>&1 | grep -q "no dynamic" && echo "==> Static binary confirmed"

echo "==> Stripping binary..."
$STRIP keepalive

install -d "${INSTALL_DIR}"
cp -f keepalive "${INSTALL_DIR}/"

echo
echo "========================================="
echo "  BUILD SUMMARY"
echo "========================================="
echo "  Version: ${VERSION}"
echo "  Binary:  $(ls -lh keepalive | awk '{print $5}')"
echo "  Install: ${INSTALL_DIR}/keepalive"
echo
echo "==> keepalive v${VERSION} static (musl/MIPS) installed in ${INSTALL_DIR}"
