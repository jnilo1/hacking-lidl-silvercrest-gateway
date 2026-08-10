#!/bin/sh
# build_ethtool.sh — Build STATIC ethtool with Lexra toolchain (musl) for RTL8196E
#
# ethtool: standard Linux network device control & diagnostic tool.
# Source: https://mirrors.edge.kernel.org/pub/software/network/ethtool/
# License: GPL-2.0
#
# This component is NOT installed in skeleton/usr/bin/ — the cross-compiled
# binary is written next to this script (./ethtool, same directory level)
# and committed, left for the operator to copy on demand.
# It is intentionally excluded from the default userdata image so that the
# 12 MB JFFS2 partition stays lean: ethtool is a debug-only tool, useful
# when investigating link state or rtl8196e-eth driver counters, but not
# something most users need.
#
# Deploy on a running gateway with:
#   scp -O ethtool root@<gateway-ip>:/userdata/usr/bin/
#
# /userdata/usr/bin is in PATH and is JFFS2-persistent across reboots.
#
# Usage:
#   ./build_ethtool.sh [version]
#
# Examples:
#   ./build_ethtool.sh           # Default version (6.10)
#   ./build_ethtool.sh 6.11      # Specific version
#
# J. Nilo - May 2026

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

VERSION="${1:-6.10}"
SOURCE_DIR="${SCRIPT_DIR}/ethtool-${VERSION}"
OUT_BIN="${SCRIPT_DIR}/ethtool"   # installed next to this script and committed

# Lexra toolchain (musl)
TOOLCHAIN_DIR="${PROJECT_ROOT}/x-tools/mips-lexra-linux-musl"
if ! command -v mips-lexra-linux-musl-gcc >/dev/null 2>&1; then
    export PATH="${TOOLCHAIN_DIR}/bin:$PATH"
fi
export CROSS_COMPILE="mips-lexra-linux-musl-"
export CC="${CROSS_COMPILE}gcc"
export AR="${CROSS_COMPILE}ar"
export RANLIB="${CROSS_COMPILE}ranlib"
export STRIP="${CROSS_COMPILE}strip"
export CFLAGS="-Os -fno-stack-protector"
export LDFLAGS="-static -Wl,-z,noexecstack,-z,relro,-z,now"

echo "========================================="
echo "  BUILDING ETHTOOL v${VERSION}"
echo "========================================="
echo ""
echo "Compiler: ${CC}"
echo "CFLAGS:   ${CFLAGS}"
echo "LDFLAGS:  ${LDFLAGS}"
echo ""

# Download if necessary
if [ ! -d "${SOURCE_DIR}" ]; then
    echo "==> Downloading ethtool-${VERSION}..."
    wget -qO- "https://mirrors.edge.kernel.org/pub/software/network/ethtool/ethtool-${VERSION}.tar.xz" \
        | tar xJ -C "${SCRIPT_DIR}"
fi

cd "${SOURCE_DIR}"

[ -f Makefile ] && make clean

# --disable-netlink: avoid the libmnl dependency. Netlink-based commands
# (e.g. ethtool --json, ethtool -m XCVR) are then not supported, but ioctl
# commands (-i, -S, -g, link state) all work — that covers the rtl8196e
# debug use cases.
./configure \
    --host=mips-lexra-linux-musl \
    --prefix=/usr \
    --disable-netlink \
    --disable-pretty-dump

make

${STRIP} ethtool
cp -f ethtool "${OUT_BIN}"

SIZE=$(ls -lh "${OUT_BIN}" | awk '{print $5}')

echo ""
echo "========================================="
echo "  BUILD SUMMARY"
echo "========================================="
echo "  Version: ${VERSION}"
echo "  Binary:  ${OUT_BIN} (${SIZE})"
echo ""
echo "  ethtool is intentionally NOT installed in skeleton/usr/bin/."
echo "  To deploy on a running gateway:"
echo ""
echo "    scp -O ${OUT_BIN} root@<gateway>:/userdata/usr/bin/"
echo ""
echo "  Then on the gateway:"
echo "    ethtool -i eth0"
echo "    ethtool eth0"
echo "    ethtool -S eth0"
echo ""
