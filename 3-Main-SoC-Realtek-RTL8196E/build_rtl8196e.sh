#!/bin/bash
# build_rtl8196e.sh — Build system components for RTL8196E
#
# Works both in Docker container and native Ubuntu 22.04 / WSL2.
#
# Prerequisites:
#   - Toolchain built: ../1-Build-Environment/10-lexra-toolchain/
#   - Tools built: ../1-Build-Environment/11-realtek-tools/
#
# Usage:
#   ./build_rtl8196e.sh                  # Build all (default)
#   ./build_rtl8196e.sh all              # Build all
#   ./build_rtl8196e.sh bootloader       # Build bootloader only
#   ./build_rtl8196e.sh kernel           # Build kernel only
#   ./build_rtl8196e.sh rootfs           # Build rootfs only
#   ./build_rtl8196e.sh userdata         # Build userdata only
#   ./build_rtl8196e.sh rootfs userdata  # Build rootfs + userdata
#   ./build_rtl8196e.sh kernel rootfs    # Build kernel + rootfs
#
# J. Nilo - December 2025

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TOOLCHAIN_DIR="${PROJECT_ROOT}/x-tools/mips-lexra-linux-musl"

# Add toolchain to PATH only if not already available (avoids GLIBC mismatch in Docker)
if ! command -v mips-lexra-linux-musl-gcc >/dev/null 2>&1; then
    if [ -d "${TOOLCHAIN_DIR}/bin" ]; then
        export PATH="${TOOLCHAIN_DIR}/bin:$PATH"
    fi
fi

# Parse arguments
BUILD_BOOTLOADER=0
BUILD_KERNEL=0
BUILD_ROOTFS=0
BUILD_USERDATA=0

if [ $# -eq 0 ] || [ "$1" = "all" ]; then
    BUILD_BOOTLOADER=1
    BUILD_KERNEL=1
    BUILD_ROOTFS=1
    BUILD_USERDATA=1
else
    for arg in "$@"; do
        case "$arg" in
            bootloader)
                BUILD_BOOTLOADER=1
                ;;
            kernel)
                BUILD_KERNEL=1
                ;;
            rootfs)
                BUILD_ROOTFS=1
                ;;
            userdata)
                BUILD_USERDATA=1
                ;;
            --help|-h)
                echo "Usage: $0 [target...]"
                echo ""
                echo "Targets:"
                echo "  all        Build everything (default)"
                echo "  bootloader Build bootloader"
                echo "  kernel     Build Linux kernel"
                echo "  rootfs     Build root filesystem (BusyBox, Dropbear)"
                echo "  userdata   Build user partition (nano, serialgateway, otbr-agent)"
                echo ""
                echo "Examples:"
                echo "  $0                     # Build all"
                echo "  $0 kernel              # Build kernel only"
                echo "  $0 rootfs userdata     # Build rootfs + userdata"
                exit 0
                ;;
            *)
                echo "Unknown target: $arg"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done
fi

echo "========================================="
echo "  BUILDING LIDL GATEWAY SYSTEM"
echo "========================================="
echo ""

# Show what will be built
echo "Targets:"
[ $BUILD_BOOTLOADER -eq 1 ] && echo "  • bootloader"
[ $BUILD_KERNEL -eq 1 ] && echo "  • kernel"
[ $BUILD_ROOTFS -eq 1 ] && echo "  • rootfs"
[ $BUILD_USERDATA -eq 1 ] && echo "  • userdata"
echo ""

# Check toolchain
if ! command -v mips-lexra-linux-musl-gcc >/dev/null 2>&1; then
    echo "ERROR: Lexra toolchain not found"
    echo ""
    echo "Build it first:"
    echo "  cd ../1-Build-Environment && sudo ./install_deps.sh"
    echo ""
    echo "Expected location: ${TOOLCHAIN_DIR}"
    exit 1
fi

echo "✅ Toolchain: $(mips-lexra-linux-musl-gcc --version | head -1)"
echo ""

# Track step number
STEP=0
TOTAL=$((BUILD_BOOTLOADER + BUILD_KERNEL + BUILD_ROOTFS + BUILD_USERDATA))
# Rootfs has 2 sub-steps (busybox + dropbear)
[ $BUILD_ROOTFS -eq 1 ] && TOTAL=$((TOTAL + 2))

# Build bootloader
if [ $BUILD_BOOTLOADER -eq 1 ]; then
    STEP=$((STEP + 1))
    echo "========================================="
    echo "  ${STEP}/${TOTAL} BUILDING BOOTLOADER"
    echo "========================================="
    cd "${SCRIPT_DIR}/31-Bootloader" && ./build_bootloader.sh
fi

# Build rootfs components
if [ $BUILD_ROOTFS -eq 1 ]; then
    STEP=$((STEP + 1))
    echo "========================================="
    echo "  ${STEP}/${TOTAL} BUILDING BUSYBOX"
    echo "========================================="
    cd "${SCRIPT_DIR}/33-Rootfs/busybox" && ./build_busybox.sh

    STEP=$((STEP + 1))
    echo ""
    echo "========================================="
    echo "  ${STEP}/${TOTAL} BUILDING DROPBEAR"
    echo "========================================="
    cd "${SCRIPT_DIR}/33-Rootfs/dropbear" && ./build_dropbear.sh

    STEP=$((STEP + 1))
    echo ""
    echo "========================================="
    echo "  ${STEP}/${TOTAL} BUILDING ROOTFS IMAGE"
    echo "========================================="
    cd "${SCRIPT_DIR}/33-Rootfs" && ./build_rootfs.sh
fi

# Build userdata
if [ $BUILD_USERDATA -eq 1 ]; then
    STEP=$((STEP + 1))
    echo ""
    echo "========================================="
    echo "  ${STEP}/${TOTAL} BUILDING USERDATA"
    echo "========================================="
    cd "${SCRIPT_DIR}/34-Userdata" && ./build_userdata.sh
fi

# Build kernel
if [ $BUILD_KERNEL -eq 1 ]; then
    STEP=$((STEP + 1))
    echo ""
    echo "========================================="
    echo "  ${STEP}/${TOTAL} BUILDING KERNEL"
    echo "========================================="
    cd "${SCRIPT_DIR}/32-Kernel" && ./build_kernel.sh
fi

echo ""
echo "========================================="
echo "  ✅ BUILD COMPLETE"
echo "========================================="
echo ""
echo "Generated images:"
[ $BUILD_BOOTLOADER -eq 1 ] && ls -lh "${SCRIPT_DIR}/31-Bootloader/boot.bin" 2>/dev/null || true
[ $BUILD_ROOTFS -eq 1 ] && ls -lh "${SCRIPT_DIR}/33-Rootfs/rootfs.bin" 2>/dev/null || true
[ $BUILD_USERDATA -eq 1 ] && ls -lh "${SCRIPT_DIR}/34-Userdata/userdata.bin" 2>/dev/null || true
[ $BUILD_KERNEL -eq 1 ] && ls -lh "${SCRIPT_DIR}/32-Kernel/kernel.img" 2>/dev/null || true
cd "$PROJECT_ROOT"
echo ""
echo "To flash: ./flash_install_rtl8196e.sh  (or flash_remote.sh for single partitions)"
echo ""
