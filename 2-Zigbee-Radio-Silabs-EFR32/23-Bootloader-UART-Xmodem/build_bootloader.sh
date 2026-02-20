#!/bin/bash
# build_bootloader.sh — Build Bootloader-UART-Xmodem for EFR32MG1B232F256GM48
#
# Works both in Docker container and native Ubuntu 22.04 / WSL2.
#
# Prerequisites:
#   - slc (Silicon Labs CLI) in PATH
#   - arm-none-eabi-gcc in PATH
#   - GECKO_SDK environment variable set
#   - commander (for post-build .gbl generation)
#
# Usage:
#   ./build_bootloader.sh           # Build bootloader
#   ./build_bootloader.sh clean     # Clean build directory
#
# Output (same as Simplicity Studio):
#   firmware/bootloader-uart-xmodem-X.Y.Z.s37          (main stage)
#   firmware/bootloader-uart-xmodem-X.Y.Z-crc.s37      (main stage with CRC)
#   firmware/bootloader-uart-xmodem-X.Y.Z-combined.s37 (first_stage + main-crc)
#   firmware/bootloader-uart-xmodem-X.Y.Z.gbl          (for XMODEM upload)
#   firmware/first_stage.s37                           (first stage bootloader)
#
# J. Nilo - December 2025

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
OUTPUT_DIR="${SCRIPT_DIR}/firmware"
PATCHES_DIR="${SCRIPT_DIR}/patches"

# Project root (for auto-detecting silabs-tools)
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SILABS_TOOLS_DIR="${PROJECT_ROOT}/silabs-tools"

# Target chip
TARGET_DEVICE="EFR32MG1B232F256GM48"

# Handle clean command
if [ "${1:-}" = "clean" ]; then
    echo "Cleaning build directory..."
    rm -rf "${BUILD_DIR}"
    echo "Done."
    exit 0
fi

echo "========================================="
echo "  Bootloader-UART-Xmodem Builder"
echo "  Target: ${TARGET_DEVICE}"
echo "========================================="
echo ""

# =========================================
# Auto-detect silabs-tools in project directory
# =========================================
if [ -d "${SILABS_TOOLS_DIR}/slc_cli" ]; then
    export PATH="${SILABS_TOOLS_DIR}/slc_cli:$PATH"
    export PATH="${SILABS_TOOLS_DIR}/arm-gnu-toolchain/bin:$PATH"
    export PATH="${SILABS_TOOLS_DIR}/commander:$PATH"
    export GECKO_SDK="${SILABS_TOOLS_DIR}/gecko_sdk"
    export JAVA_TOOL_OPTIONS="-Duser.home=${SILABS_TOOLS_DIR}"
fi

# =========================================
# Check prerequisites
# =========================================

# Check slc
if ! command -v slc >/dev/null 2>&1; then
    echo "slc (Silicon Labs CLI) not found in PATH"
    echo ""
    echo "Setup options:"
    echo "  1. Use Docker: docker run -it --rm -v \$(pwd):/workspace lidl-gateway-builder"
    echo "  2. Native: cd 1-Build-Environment/12-silabs-toolchain && ./install_silabs.sh"
    exit 1
fi
SLC_VERSION=$(slc --version 2>/dev/null | head -1)
SLC_MAJOR=$(echo "$SLC_VERSION" | grep -oE '^[0-9]+')
echo "slc: ${SLC_VERSION}"
if [ "$SLC_MAJOR" != "5" ]; then
    echo "WARNING: slc-cli version ${SLC_MAJOR}.x detected, tested with 5.11.x"
fi

# Check ARM GCC
if ! command -v arm-none-eabi-gcc >/dev/null 2>&1; then
    echo "arm-none-eabi-gcc not found in PATH"
    exit 1
fi
echo "ARM GCC: $(arm-none-eabi-gcc --version | head -1)"

# Check GECKO_SDK
if [ -z "${GECKO_SDK:-}" ]; then
    # Try common locations
    if [ -d "${SILABS_TOOLS_DIR}/gecko_sdk" ]; then
        export GECKO_SDK="${SILABS_TOOLS_DIR}/gecko_sdk"
    elif [ -d "/home/builder/gecko_sdk" ]; then
        export GECKO_SDK="/home/builder/gecko_sdk"
    elif [ -d "$HOME/silabs/gecko_sdk" ]; then
        export GECKO_SDK="$HOME/silabs/gecko_sdk"
    elif [ -d "$HOME/gecko_sdk" ]; then
        export GECKO_SDK="$HOME/gecko_sdk"
    else
        echo "GECKO_SDK environment variable not set"
        echo ""
        echo "Install Silabs tools first:"
        echo "  cd 1-Build-Environment/12-silabs-toolchain && ./install_silabs.sh"
        exit 1
    fi
fi

if [ ! -d "${GECKO_SDK}/platform/bootloader" ]; then
    echo "Gecko SDK bootloader not found: ${GECKO_SDK}/platform/bootloader"
    exit 1
fi
echo "Gecko SDK: ${GECKO_SDK}"

# Check commander (required for post-build)
if ! command -v commander >/dev/null 2>&1; then
    echo ""
    echo "ERROR: commander not found in PATH"
    echo "commander is required for post-build (.gbl generation)"
    echo ""
    echo "Install Silabs tools first:"
    echo "  cd 1-Build-Environment/12-silabs-toolchain && ./install_silabs.sh"
    exit 1
fi
echo "Commander: $(commander --version 2>/dev/null | head -1)"

# =========================================
# Extract SDK and Bootloader versions
# =========================================
SDK_VERSION_FILE="${GECKO_SDK}/version.txt"
if [ -f "${SDK_VERSION_FILE}" ]; then
    SDK_VERSION=$(cat "${SDK_VERSION_FILE}" | head -1)
    echo "SDK Version: ${SDK_VERSION}"
else
    SDK_VERSION="unknown"
fi

# Extract bootloader version from SDK
BTL_CONFIG="${GECKO_SDK}/platform/bootloader/config/btl_config.h"
if [ -f "${BTL_CONFIG}" ]; then
    BTL_MAJOR=$(grep "BOOTLOADER_VERSION_MAIN_MAJOR" "${BTL_CONFIG}" | head -1 | awk '{print $3}')
    BTL_MINOR=$(grep "BOOTLOADER_VERSION_MAIN_MINOR" "${BTL_CONFIG}" | head -1 | awk '{print $3}')
    BTL_CUSTOMER=$(grep "BOOTLOADER_VERSION_MAIN_CUSTOMER" "${BTL_CONFIG}" | grep -v ifndef | head -1 | awk '{print $3}')
    BTL_VERSION="${BTL_MAJOR}.${BTL_MINOR}.${BTL_CUSTOMER}"
    echo "Bootloader Version: ${BTL_VERSION}"
else
    BTL_VERSION="unknown"
fi
echo ""

# =========================================
# Prepare build directory
# =========================================
echo "[1/5] Preparing build directory..."
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

# Copy project files from patches
cp "${PATCHES_DIR}/bootloader-uart-xmodem.slcp" .
cp "${PATCHES_DIR}/bootloader-uart-xmodem.slpb" .
echo "  - Copied project files from patches"

# =========================================
# Generate project with slc
# =========================================
echo ""
echo "[2/5] Generating project with slc..."
slc generate bootloader-uart-xmodem.slcp --sdk "${GECKO_SDK}" --with ${TARGET_DEVICE} --force 2>&1 | tail -3

# =========================================
# Copy config files and patch Makefile
# =========================================
echo ""
echo "[3/5] Applying configuration..."
cp "${PATCHES_DIR}/btl_uart_driver_cfg.h" config/
echo "  - Copied UART config from patches"

echo "  Patching Makefile..."
ARM_GCC_DIR=$(dirname $(dirname $(which arm-none-eabi-gcc)))
echo "  - Setting ARM_GCC_DIR to ${ARM_GCC_DIR}"
sed -i "s|^ARM_GCC_DIR_LINUX\s*=.*|ARM_GCC_DIR_LINUX = ${ARM_GCC_DIR}|" bootloader-uart-xmodem.Makefile

# Add -Oz optimization
if ! grep -q 'subst -Os,-Oz' bootloader-uart-xmodem.Makefile; then
    echo "  - Adding -Oz optimization to Makefile"
    sed -i '/-include bootloader-uart-xmodem.project.mak/a\
\
# Override optimization flags for maximum size reduction\
C_FLAGS := $(subst -Os,-Oz,$(C_FLAGS))\
CXX_FLAGS := $(subst -Os,-Oz,$(CXX_FLAGS))' bootloader-uart-xmodem.Makefile
fi

# =========================================
# Compile
# =========================================
echo ""
echo "[4/5] Compiling bootloader..."
make -f bootloader-uart-xmodem.Makefile -j$(nproc)

# =========================================
# Post-build: Generate output files (same as Simplicity Studio)
# =========================================
echo ""
echo "[5/5] Post-build: Generating output files..."

# Create artifact directory (as in Simplicity Studio)
mkdir -p artifact
mkdir -p "${OUTPUT_DIR}"

OUTPUT_NAME="bootloader-uart-xmodem-${BTL_VERSION}"
SRC_OUT="build/debug/bootloader-uart-xmodem.out"

if [ ! -f "${SRC_OUT}" ]; then
    echo "  Error: No .out file found!"
    exit 1
fi

echo "  Post-build steps (matching Simplicity Studio .slpb):"

# Step 1: Convert .out to .s37 (main stage)
echo "  1. Convert .out → .s37 (main stage)"
commander convert "${SRC_OUT}" --outfile "artifact/bootloader-uart-xmodem.s37"

# Step 2: Convert to .s37 with CRC
echo "  2. Convert .s37 → -crc.s37 (with CRC)"
commander convert "artifact/bootloader-uart-xmodem.s37" --crc --outfile "artifact/bootloader-uart-xmodem-crc.s37"

# Step 3: Combine first_stage + main-crc
echo "  3. Combine first_stage.s37 + -crc.s37 → -combined.s37"
if [ -f "autogen/first_stage.s37" ]; then
    commander convert "autogen/first_stage.s37" "artifact/bootloader-uart-xmodem-crc.s37" \
        --outfile "artifact/bootloader-uart-xmodem-combined.s37"
else
    echo "     Warning: autogen/first_stage.s37 not found, skipping combined image"
fi

# Step 4: Create .gbl file for XMODEM upload
echo "  4. Create .gbl (for XMODEM upload)"
commander gbl create "artifact/bootloader-uart-xmodem.gbl" \
    --bootloader "artifact/bootloader-uart-xmodem-crc.s37"

# =========================================
# Copy to firmware directory with version suffix
# =========================================
echo ""
echo "  Copying artifacts to firmware/..."

# Main stage
cp "artifact/bootloader-uart-xmodem.s37" "${OUTPUT_DIR}/${OUTPUT_NAME}.s37"

# Main stage with CRC
cp "artifact/bootloader-uart-xmodem-crc.s37" "${OUTPUT_DIR}/${OUTPUT_NAME}-crc.s37"

# Combined (first_stage + main-crc)
if [ -f "artifact/bootloader-uart-xmodem-combined.s37" ]; then
    cp "artifact/bootloader-uart-xmodem-combined.s37" "${OUTPUT_DIR}/${OUTPUT_NAME}-combined.s37"
fi

# GBL for XMODEM upload
cp "artifact/bootloader-uart-xmodem.gbl" "${OUTPUT_DIR}/${OUTPUT_NAME}.gbl"

# First stage (copy separately)
if [ -f "autogen/first_stage.s37" ]; then
    cp "autogen/first_stage.s37" "${OUTPUT_DIR}/first_stage.s37"
fi

# =========================================
# Summary
# =========================================
echo ""
echo "========================================="
echo "  BUILD COMPLETE"
echo "========================================="
echo ""
echo "SDK Version: ${SDK_VERSION}"
echo "Bootloader Version: ${BTL_VERSION}"
echo ""
echo "Bootloader size:"
arm-none-eabi-size build/debug/bootloader-uart-xmodem.out
echo ""
echo "Output files (same as Simplicity Studio artifact/):"
ls -lh "${OUTPUT_DIR}/"
echo ""
echo "Files for flashing:"
echo "  ${OUTPUT_NAME}.s37          - Main stage bootloader"
echo "  ${OUTPUT_NAME}-crc.s37      - Main stage with CRC (for serial upload)"
echo "  ${OUTPUT_NAME}-combined.s37 - First stage + Main stage (for J-Link)"
echo "  ${OUTPUT_NAME}.gbl          - GBL image (for XMODEM upload)"
echo "  first_stage.s37             - First stage only (requires J-Link)"
echo ""
echo "Flash combined image via J-Link:"
echo "  commander flash firmware/${OUTPUT_NAME}-combined.s37 --device ${TARGET_DEVICE}"
echo ""
echo "Upload via XMODEM (if bootloader already installed):"
echo "  Use firmware/${OUTPUT_NAME}.gbl"
echo ""
