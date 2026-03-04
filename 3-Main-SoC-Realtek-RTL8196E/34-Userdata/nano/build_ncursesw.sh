#!/bin/sh
# build_ncursesw.sh — Build STATIC ncursesw with Lexra toolchain (musl 1.2.5) for RTL8196E
#
# ncurses: Terminal handling library (wide character version)
# Source: https://ftp.gnu.org/gnu/ncurses/
# License: MIT
#
# J. Nilo - Dec 2025

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Project root is 4 levels up: nano -> 34-Userdata -> 3-Main-SoC -> project root
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

# Configuration
VERSION="6.5"
SOURCE_DIR="${SCRIPT_DIR}/ncurses-${VERSION}"
INSTALL_PREFIX="${SCRIPT_DIR}/ncursesw-install"

# Download if necessary (into script directory)
if [ ! -d "$SOURCE_DIR" ]; then
    echo "Downloading ncurses-${VERSION}..."
    wget -qO- https://ftp.gnu.org/gnu/ncurses/ncurses-${VERSION}.tar.gz | tar xz -C "${SCRIPT_DIR}"
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

# Build
cd "$SOURCE_DIR"
[ -f Makefile ] && make clean || true

./configure \
  --host=mips-lexra-linux-musl \
  --prefix="$INSTALL_PREFIX" \
  --without-cxx \
  --without-cxx-binding \
  --without-ada \
  --without-manpages \
  --without-progs \
  --without-tests \
  --without-debug \
  --without-profile \
  --without-shared \
  --with-normal \
  --enable-widec \
  --disable-database \
  --with-fallbacks=vt100,vt102,xterm,xterm-256color,linux \
  --disable-db-install \
  --without-dlsym

make
make install

echo "✅ ncursesw installed in $INSTALL_PREFIX"
