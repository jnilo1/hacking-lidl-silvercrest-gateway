#!/bin/bash
# build_rootfs.sh — Build SquashFS root filesystem for RTL8196E
#
# This script:
#   - Creates a SquashFS image from skeleton/ directory
#   - Adds device nodes (console, null, zero)
#   - Converts to RTL bootloader format with cvimg
#
# Output: rootfs.bin (ready to flash)
#
# Usage:
#   ./build_rootfs.sh              # Normal build
#   ./build_rootfs.sh -q           # Quiet mode (used by flash_rootfs.sh)
#
# J. Nilo - November 2025

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="${SCRIPT_DIR}/.."

QUIET=0
for arg in "$@"; do
    case "$arg" in
        -q|--quiet) QUIET=1 ;;
    esac
done

log() { [ "$QUIET" -eq 0 ] && echo "$@" || true; }

# Check that fakeroot is installed
if ! command -v fakeroot >/dev/null 2>&1; then
    echo "❌ fakeroot is not installed"
    echo "   Installation: sudo apt-get install fakeroot"
    exit 1
fi

# Check that cvimg is available, build it if missing
BUILD_ENV="${PROJECT_ROOT}/../1-Build-Environment/11-realtek-tools"
CVIMG_TOOL="${BUILD_ENV}/bin/cvimg"
if [ ! -f "$CVIMG_TOOL" ]; then
    echo "cvimg not found — building it..."
    if ! command -v gcc >/dev/null 2>&1; then
        echo "Error: gcc not found (needed to compile cvimg)." >&2
        echo "Install it with: sudo apt install gcc" >&2
        exit 1
    fi
    CVIMG_SRC="${BUILD_ENV}/cvimg/cvimg.c"
    if [ ! -f "$CVIMG_SRC" ]; then
        echo "Error: cvimg source not found at ${CVIMG_SRC}" >&2
        exit 1
    fi
    mkdir -p "${BUILD_ENV}/bin"
    gcc -std=c99 -Wall -O2 -D_GNU_SOURCE -o "$CVIMG_TOOL" "$CVIMG_SRC" || {
        echo "Error: failed to compile cvimg" >&2
        exit 1
    }
    echo "cvimg built."
fi

cd "${SCRIPT_DIR}"

# Rebuild dropbear if binary is missing (symlinks are in git, binary is not)
if [ ! -f skeleton/bin/dropbearmulti ]; then
    echo "dropbearmulti not found — rebuilding..."
    "${SCRIPT_DIR}/dropbear/build_dropbear.sh"
fi

log "========================================="
log "  BUILDING ROOT FILESYSTEM"
log "========================================="
log ""

# Ensure /dev directory exists in skeleton
log "🔧 Preparing /dev structure..."
mkdir -p skeleton/dev

# Clean old images
rm -f rootfs.sqfs rootfs.bin

# Fix /root permissions for Dropbear pubkey auth (git doesn't preserve dir modes)
chmod 750 skeleton/root

log "📦 Generating SquashFS with device nodes..."
if [ "$QUIET" -eq 1 ]; then
    fakeroot mksquashfs skeleton rootfs.sqfs \
      -nopad -noappend -all-root \
      -comp xz -b 256k \
      -p "/dev/console c 600 0 0 5 1" \
      -p "/dev/null c 666 0 0 1 3" \
      -p "/dev/zero c 666 0 0 1 5" -quiet -no-progress
else
    fakeroot mksquashfs skeleton rootfs.sqfs \
      -nopad -noappend -all-root \
      -comp xz -b 256k \
      -p "/dev/console c 600 0 0 5 1" \
      -p "/dev/null c 666 0 0 1 3" \
      -p "/dev/zero c 666 0 0 1 5"
fi

if [ "$QUIET" -eq 0 ]; then
    echo ""
    echo "🔍 Verifying device nodes in image..."
    if unsquashfs -ll rootfs.sqfs 2>/dev/null | grep -q "dev/console"; then
        echo "✅ /dev/console found in rootfs"
        unsquashfs -ll rootfs.sqfs 2>/dev/null | grep "dev/" | head -10
    else
        echo "⚠️  /dev/console NOT found in rootfs"
    fi
    echo ""
    echo "🔧 Converting to RTL format..."
    $CVIMG_TOOL \
        -i rootfs.sqfs \
        -o rootfs.bin \
        -e 0x80c00000 \
        -b 0x200000 \
        -s r6cr
else
    $CVIMG_TOOL \
        -i rootfs.sqfs \
        -o rootfs.bin \
        -e 0x80c00000 \
        -b 0x200000 \
        -s r6cr >/dev/null
fi

# Remove intermediate file
rm -f rootfs.sqfs

log ""
log "========================================="
log "  BUILD SUMMARY"
log "========================================="
if [ "$QUIET" -eq 0 ]; then
    ls -lh rootfs.bin
    echo ""
    echo "Rootfs image ready: rootfs.bin ($(ls -lh rootfs.bin | awk '{print $5}'))"
    echo ""
    echo "To flash: ./flash_rootfs.sh"
else
    echo "rootfs.bin built ($(ls -lh rootfs.bin | awk '{print $5}'))"
fi
