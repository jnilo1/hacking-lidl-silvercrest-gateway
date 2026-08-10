#!/bin/sh
# build_wireguard.sh — Build static WireGuard userspace for RTL8196E
#
# Produces wg(8) and wg-link.  wg-link fills the single gap in the BusyBox ip
# applet: creating or deleting a link of type "wireguard".
#
# The binaries land in optional/usr/{bin,sbin}/ and are NOT part of the shipped
# userdata image: the stock kernels do not build in the WireGuard driver, so
# this tooling cannot bring a tunnel up as-is.  See README.md in this directory
# for why, and for how to install it on a gateway that wants it.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
VERSION="${1:-1.0.20260223}"
SOURCE_DIR="${SCRIPT_DIR}/wireguard-tools-${VERSION}"
INSTALL_BIN="${SCRIPT_DIR}/optional/usr/bin"
INSTALL_SBIN="${SCRIPT_DIR}/optional/usr/sbin"

TOOLCHAIN_DIR="${PROJECT_ROOT}/x-tools/mips-lexra-linux-musl"
if ! command -v mips-lexra-linux-musl-gcc >/dev/null 2>&1; then
    export PATH="${TOOLCHAIN_DIR}/bin:${PATH}"
fi
export CROSS_COMPILE="mips-lexra-linux-musl-"
export CC="${CROSS_COMPILE}gcc"
export AR="${CROSS_COMPILE}ar"
export RANLIB="${CROSS_COMPILE}ranlib"
export STRIP="${CROSS_COMPILE}strip"
export CFLAGS="-Os -fno-stack-protector"
export LDFLAGS="-static -Wl,-z,noexecstack,-z,relro,-z,now"

if ! command -v "${CC}" >/dev/null 2>&1; then
    echo "Error: Lexra compiler not found: ${CC}" >&2
    exit 1
fi

if [ ! -d "${SOURCE_DIR}" ]; then
    echo "Downloading wireguard-tools-${VERSION}..."
    wget -qO- "https://git.zx2c4.com/wireguard-tools/snapshot/wireguard-tools-${VERSION}.tar.xz" \
        | tar xJ -C "${SCRIPT_DIR}"
fi
[ -f "${SOURCE_DIR}/src/Makefile" ] || {
    echo "Error: ${SOURCE_DIR} is not a wireguard-tools source tree" >&2
    exit 1
}

make -C "${SOURCE_DIR}/src" clean
make -C "${SOURCE_DIR}/src" RUNSTATEDIR=/var/run \
    CC="${CC}" AR="${AR}" RANLIB="${RANLIB}"
"${STRIP}" "${SOURCE_DIR}/src/wg"

mkdir -p "${INSTALL_BIN}" "${INSTALL_SBIN}"
"${CC}" ${CFLAGS} ${LDFLAGS} -o "${INSTALL_SBIN}/wg-link" "${SCRIPT_DIR}/src/wg_link.c"
"${STRIP}" "${INSTALL_SBIN}/wg-link"
cp -f "${SOURCE_DIR}/src/wg" "${INSTALL_BIN}/wg"

echo "WireGuard tools ready (NOT shipped in userdata.bin -- see README.md):"
ls -lh "${INSTALL_BIN}/wg" "${INSTALL_SBIN}/wg-link"
