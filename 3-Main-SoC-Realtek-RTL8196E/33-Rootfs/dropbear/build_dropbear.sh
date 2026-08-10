#!/bin/sh
# build_dropbear.sh — Build dropbear for the RTL8196E
#
# Usage:
#   ./build_dropbear.sh [version]
#
# Examples:
#   ./build_dropbear.sh              # Default version (2026.94)
#   ./build_dropbear.sh 2025.89      # Specific version
#
# J. Nilo April 2025

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOTFS_PART="${SCRIPT_DIR}/.."
# Project root is 4 levels up: dropbear -> 33-Rootfs -> 3-Main-SoC -> project root
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

# Source trees are extracted next to this script, whatever the caller's cwd —
# every path below the download is relative, so running it from elsewhere used
# to scatter a DROPBEAR_<version>/ tree wherever the shell happened to be.
cd "${SCRIPT_DIR}"

# Parse version argument
VERSION="${1:-2026.94}"
SOURCE_DIR="DROPBEAR_${VERSION}"
INSTALL_DIR="${ROOTFS_PART}/skeleton/bin"

echo "📦 Dropbear version: ${VERSION}"

# Download if necessary
if [ ! -d "$SOURCE_DIR" ]; then
    echo "📥 Downloading dropbear ${VERSION}..."
    wget -qO- "https://github.com/mkj/dropbear/archive/refs/tags/${SOURCE_DIR}.tar.gz" | tar xz
    mv "dropbear-${SOURCE_DIR}" "$SOURCE_DIR"
fi

# Toolchain
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

# Build
cd "$SOURCE_DIR"
[ -f Makefile ] && make clean
rm -f "$INSTALL_DIR"/dropbear*

./configure \
  --host=mips-lexra-linux-musl \
  --disable-zlib \
  --disable-utmp \
  --disable-wtmp \
  --disable-lastlog \
  --disable-loginfunc \
  --disable-pututline \
  --disable-pututxline \
  --disable-shadow \
  --disable-pam \
  --enable-static \
  --disable-utmpx \
  --disable-wtmpx

make PROGRAMS="dropbearmulti dropbear dropbearkey dbclient scp" MULTI=1 SCPPROGRESS=1
${STRIP} dropbearmulti

mkdir -p "$INSTALL_DIR"
cp dropbearmulti "$INSTALL_DIR"/
ln -sf dropbearmulti "$INSTALL_DIR"/dropbear
ln -sf dropbearmulti "$INSTALL_DIR"/dropbearkey
ln -sf dropbearmulti "$INSTALL_DIR"/dbclient
ln -sf dropbearmulti "$INSTALL_DIR"/scp

echo ""
echo "📊 Build summary:"
echo "  • Version: ${VERSION}"
echo "  • Binary: $(ls -lh dropbearmulti | awk '{print $5}')"
echo "  • Programs: dropbear, dropbearkey, dbclient, scp"
echo "  • Installation: ${INSTALL_DIR}"
echo ""
echo "✅ dropbear, dropbearkey, dbclient & scp installed in $INSTALL_DIR"
