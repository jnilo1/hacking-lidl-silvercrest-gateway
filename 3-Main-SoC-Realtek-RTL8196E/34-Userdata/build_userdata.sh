#!/bin/bash
# build_userdata.sh — Build JFFS2 userdata partition for RTL8196E
#
# This script:
#   - Builds nano editor + serialgateway (unless --jffs2-only)
#   - Creates JFFS2 filesystem from skeleton/ directory
#   - Converts to RTL bootloader format with cvimg
#
# Usage:
#   ./build_userdata.sh                       # Build nano + serialgateway + JFFS2
#   ./build_userdata.sh --jffs2-only          # Build JFFS2 only (no compile)
#   ./build_userdata.sh --jffs2-only -q       # Quiet mode (used by build_fullflash)
#
# Available components:
#   +-----------------+----------------------------------------------+-------------+
#   | Component       | Source                                       | License     |
#   +-----------------+----------------------------------------------+-------------+
#   | nano            | https://www.nano-editor.org/                 | GPL-3.0     |
#   | serialgateway   | https://github.com/banksy-git/lidl-gateway-freedom | GPL-3.0 |
#   | ncursesw        | https://ftp.gnu.org/gnu/ncurses/             | MIT         |
#   +-----------------+----------------------------------------------+-------------+
#
# Note: vi is a symlink to nano (OpenVi doesn't support UTF-8/emojis)
#
# Output: userdata.bin (ready to flash)
#
# Flash: GD25Q127 (16MB SPI NOR, 64KB erase blocks)
#
# J. Nilo - December 2025

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="${SCRIPT_DIR}/.."
INSTALL_DIR="${SCRIPT_DIR}/skeleton/usr/bin"

BUILD_COMPONENTS=1
QUIET=0

# Parse arguments
for arg in "$@"; do
    case $arg in
        --jffs2-only)
            BUILD_COMPONENTS=0
            ;;
        -q|--quiet)
            QUIET=1
            ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --jffs2-only     Build JFFS2 only (assumes binaries exist)"
            echo "  -q, --quiet      Suppress non-essential output"
            echo "  --help, -h       Show this help"
            echo ""
            echo "Components built:"
            echo "  nano             GNU nano editor (with vi symlink)"
            echo "  serialgateway    TCP-to-serial bridge for Zigbee"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Check that fakeroot is installed
if ! command -v fakeroot >/dev/null 2>&1; then
    echo "fakeroot is not installed"
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

log() { [ "$QUIET" -eq 0 ] && echo "$@" || true; }

# Build components if requested
if [ "$BUILD_COMPONENTS" -eq 1 ]; then
    echo "========================================="
    echo "  BUILDING USERDATA COMPONENTS"
    echo "========================================="
    echo ""
    echo "  Editor: nano (with vi symlink)"
    echo "  Serial: serialgateway"
    echo ""

    # Clean previous binaries
    rm -f "${INSTALL_DIR}/nano" "${INSTALL_DIR}/vi"
    rm -f "${INSTALL_DIR}/serialgateway"

    # Build nano (creates vi symlink)
    echo "========================================="
    echo "  BUILDING NANO"
    echo "========================================="
    if [ -x "${SCRIPT_DIR}/nano/build_nano.sh" ]; then
        "${SCRIPT_DIR}/nano/build_nano.sh"
    else
        echo "Error: nano/build_nano.sh not found or not executable"
        exit 1
    fi
    echo ""

    # Build serialgateway
    echo "========================================="
    echo "  BUILDING SERIALGATEWAY"
    echo "========================================="
    if [ -x "${SCRIPT_DIR}/serialgateway/build_serialgateway.sh" ]; then
        "${SCRIPT_DIR}/serialgateway/build_serialgateway.sh"
    else
        echo "Error: serialgateway/build_serialgateway.sh not found or not executable"
        exit 1
    fi
    echo ""
fi

log "========================================="
log "  BUILDING USERDATA PARTITION"
log "========================================="
log ""

# Clean old images
rm -f userdata.raw.jffs2 userdata.jffs2 userdata.bin

# Use skeleton directory directly
SKELETON_DIR="${SCRIPT_DIR}/skeleton"
if [ ! -d "$SKELETON_DIR" ]; then
    echo "skeleton directory not found"
    exit 1
fi

log "Binaries installed:"
if [ "$QUIET" -eq 0 ]; then
    ls -lh "$INSTALL_DIR" 2>/dev/null || echo "  (none)"
fi
log ""

# JFFS2 image creation with sumtool optimization
# Partition mtd3 spans 0x400000-0x1000000 -> 0xC00000 bytes (12MB).
# cvimg sets Header.len = payload_size + 2 (checksum). To make burnLen fit exactly
# 0xC00000, we pad the final JFFS2 to 0xC00000 - 2 = 0xBFFFFE.
# NOTE: Keep erase size in sync with kernel MTD layout. Here: 64KB (SPI NOR).
ERASEBLOCK_HEX=0x10000
PARTITION_SIZE_HEX=0xC00000
JFFS2_PAD_HEX=$((PARTITION_SIZE_HEX - 2))

log "Generating JFFS2 (big endian, 64KB eraseblocks, zlib, padded to ${JFFS2_PAD_HEX} bytes)..."
# Force zlib-only compression - requires CONFIG_JFFS2_ZLIB=y in kernel
fakeroot mkfs.jffs2 \
  -r "$SKELETON_DIR" \
  -o "${SCRIPT_DIR}/userdata.jffs2" \
  -e ${ERASEBLOCK_HEX} \
  -b \
  -n \
  --squash \
  --pad=${JFFS2_PAD_HEX} \
  -X zlib

log "JFFS2 image created"
log ""

# Convert to RTL format
log "Converting to RTL format (signature r6cr)..."
if [ "$QUIET" -eq 1 ]; then
    $CVIMG_TOOL \
        -i userdata.jffs2 \
        -o userdata.bin \
        -e 0x80c00000 \
        -b 0x400000 \
        -s r6cr >/dev/null
else
    $CVIMG_TOOL \
        -i userdata.jffs2 \
        -o userdata.bin \
        -e 0x80c00000 \
        -b 0x400000 \
        -s r6cr
fi

# Remove intermediate file
rm -f userdata.jffs2

log ""
log "========================================="
log "  BUILD SUMMARY"
log "========================================="
if [ "$BUILD_COMPONENTS" -eq 1 ] && [ "$QUIET" -eq 0 ]; then
    echo "  Editor: nano (vi -> nano symlink)"
    echo "  Serial: serialgateway"
fi
log ""
if [ "$QUIET" -eq 0 ]; then
    ls -lh userdata.bin
    echo ""
fi
log "Userdata image ready: userdata.bin ($(ls -lh userdata.bin | awk '{print $5}'))"
log ""
log "To flash: ./flash_userdata.sh"
