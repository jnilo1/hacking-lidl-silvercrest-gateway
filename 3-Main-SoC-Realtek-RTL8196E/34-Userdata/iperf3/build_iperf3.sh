#!/bin/sh
# build_iperf3.sh — Build STATIC iperf3 with Lexra toolchain (musl) for RTL8196E
#
# iperf3: TCP/UDP/SCTP network performance measurement tool.
# Source: https://downloads.es.net/pub/iperf/
# License: BSD-3-Clause
#
# Like the sibling ethtool/ build, this component is NOT installed in
# skeleton/usr/bin/. The cross-compiled binary is written next to this
# script (./iperf3, same directory level) and committed, left for the
# operator to copy on demand. iperf3 is a perf-tuning tool, not
# something most users need; keeping it out of the default 12 MB JFFS2
# image leaves room for OTBR + nano + s40button + boothold without juggling.
#
# Deploy on a running gateway with:
#   scp -O iperf3 root@<gateway-ip>:/userdata/usr/bin/
#
# /userdata/usr/bin is in PATH and is JFFS2-persistent across reboots.
#
# Usage:
#   ./build_iperf3.sh [version]
#
# Examples:
#   ./build_iperf3.sh           # Default version (3.18)
#   ./build_iperf3.sh 3.17.1    # Specific version
#
# J. Nilo - May 2026

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

VERSION="${1:-3.18}"
SOURCE_DIR="${SCRIPT_DIR}/iperf-${VERSION}"
OUT_BIN="${SCRIPT_DIR}/iperf3"   # installed next to this script and committed

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
# -Wno-error=incompatible-pointer-types: iperf-3.18's public callback setters
# (iperf_set_on_*_callback in src/iperf_api.c) are declared K&R-style as
# "void (*callback)()" and assigned to typed members. GCC 14+ promotes
# -Wincompatible-pointer-types from a warning to a hard error by default, so
# the build aborts with the current Lexra toolchain (GCC 15.x). Downgrading it
# back to a warning keeps the build working; harmless on older compilers.
export CFLAGS="-Os -fno-stack-protector -Wno-error=incompatible-pointer-types"
# LDFLAGS at configure time: hardening flags only. iperf3 is libtool-built;
# libtool intercepts a bare "-static" and silently drops it. The fully-static
# link is forced at make time via LDFLAGS="-all-static" below — that's the
# libtool-recognised flag that produces a true ELF static binary.
export LDFLAGS="-Wl,-z,noexecstack,-z,relro,-z,now"

echo "========================================="
echo "  BUILDING IPERF3 v${VERSION}"
echo "========================================="
echo ""
echo "Compiler: ${CC}"
echo "CFLAGS:   ${CFLAGS}"
echo "LDFLAGS:  ${LDFLAGS}"
echo ""

# Download if necessary
if [ ! -d "${SOURCE_DIR}" ]; then
    echo "==> Downloading iperf-${VERSION}..."
    wget -qO- "https://downloads.es.net/pub/iperf/iperf-${VERSION}.tar.gz" \
        | tar xz -C "${SCRIPT_DIR}"
fi

cd "${SOURCE_DIR}"

[ -f Makefile ] && make clean

# --without-openssl: drop OpenSSL dependency (used only for --authentication
# which we don't need on a private gateway).
# --disable-shared: emit only the static .a, the executable then links static.
./configure \
    --host=mips-lexra-linux-musl \
    --prefix=/usr \
    --without-openssl \
    --disable-shared

make LDFLAGS="-all-static -Wl,-z,noexecstack,-z,relro,-z,now"

${STRIP} src/iperf3
cp -f src/iperf3 "${OUT_BIN}"

SIZE=$(ls -lh "${OUT_BIN}" | awk '{print $5}')

echo ""
echo "========================================="
echo "  BUILD SUMMARY"
echo "========================================="
echo "  Version: ${VERSION}"
echo "  Binary:  ${OUT_BIN} (${SIZE})"
echo ""
echo "  iperf3 is intentionally NOT installed in skeleton/usr/bin/."
echo "  To deploy on a running gateway:"
echo ""
echo "    scp -O ${OUT_BIN} root@<gateway>:/userdata/usr/bin/"
echo ""
echo "  Then on the gateway (server side):"
echo "    iperf3 -s"
echo ""
echo "  And from the host (client side):"
echo "    iperf3 -c <gateway-ip>            # TCP RX from gateway perspective"
echo "    iperf3 -c <gateway-ip> -R         # TCP TX from gateway perspective"
echo "    iperf3 -c <gateway-ip> -u -b 100M # UDP 100 Mbit/s"
echo ""
