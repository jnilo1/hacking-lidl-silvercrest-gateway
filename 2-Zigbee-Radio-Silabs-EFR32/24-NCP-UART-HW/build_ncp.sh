#!/bin/bash
# build_ncp.sh — Build NCP-UART-HW firmware for EFR32MG1B232F256GM48
#
# Works both in Docker container and native Ubuntu 22.04 / WSL2.
#
# Prerequisites:
#   - slc (Silicon Labs CLI) in PATH
#   - arm-none-eabi-gcc in PATH
#   - GECKO_SDK environment variable set
#
# Usage:
#   ./build_ncp.sh           # Build firmware
#   ./build_ncp.sh clean     # Clean build directory
#
# Output:
#   firmware/ncp-uart-hw.gbl  (ready to flash via UART/Xmodem)
#   firmware/ncp-uart-hw.s37  (for J-Link/SWD flashing)
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
echo "  NCP-UART-HW Firmware Builder"
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

if [ ! -d "${GECKO_SDK}/protocol/zigbee" ]; then
    echo "Gecko SDK not found or incomplete: ${GECKO_SDK}"
    exit 1
fi
echo "Gecko SDK: ${GECKO_SDK}"

# =========================================
# Extract EmberZNet version from SDK
# =========================================
EMBER_CONFIG="${GECKO_SDK}/protocol/zigbee/stack/config/config.h"
if [ -f "${EMBER_CONFIG}" ]; then
    EMBER_MAJOR=$(grep '#define EMBER_MAJOR_VERSION' "${EMBER_CONFIG}" | awk '{print $3}')
    EMBER_MINOR=$(grep '#define EMBER_MINOR_VERSION' "${EMBER_CONFIG}" | awk '{print $3}')
    EMBER_PATCH=$(grep '#define EMBER_PATCH_VERSION' "${EMBER_CONFIG}" | awk '{print $3}')
    EMBERZNET_VERSION="${EMBER_MAJOR}.${EMBER_MINOR}.${EMBER_PATCH}"
    echo "EmberZNet: ${EMBERZNET_VERSION}"
else
    EMBERZNET_VERSION="unknown"
    echo "Warning: Could not determine EmberZNet version"
fi
echo ""

# =========================================
# Prepare build directory
# =========================================
echo "[1/4] Preparing build directory..."
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

# Copy project files from patches
cp "${PATCHES_DIR}/ncp-uart-hw.slcp" .
cp "${PATCHES_DIR}/main.c" .
cp "${PATCHES_DIR}/app.c" .
echo "  - Copied project files from patches"

# =========================================
# Generate project with slc
# =========================================
echo ""
echo "[2/4] Generating project with slc..."
slc generate ncp-uart-hw.slcp --sdk "${GECKO_SDK}" --with ${TARGET_DEVICE} --force 2>&1 | tail -3

# =========================================
# Copy config files and patch Makefile
# =========================================
echo ""
echo "[3/4] Applying configuration..."
cp "${PATCHES_DIR}/sl_iostream_usart_vcom_config.h" config/
cp "${PATCHES_DIR}/sl_rail_util_pti_config.h" config/
echo "  - Copied UART and PTI config from patches"

echo "  Patching Makefile..."
ARM_GCC_DIR=$(dirname $(dirname $(which arm-none-eabi-gcc)))
echo "  - Setting ARM_GCC_DIR to ${ARM_GCC_DIR}"
sed -i "s|^ARM_GCC_DIR_LINUX\s*=.*|ARM_GCC_DIR_LINUX = ${ARM_GCC_DIR}|" ncp-uart-hw.Makefile

# Add -Oz optimization
if ! grep -q 'subst -Os,-Oz' ncp-uart-hw.Makefile; then
    echo "  - Adding -Oz optimization to Makefile"
    sed -i '/-include ncp-uart-hw.project.mak/a\
\
# Override optimization flags for maximum size reduction\
C_FLAGS := $(subst -Os,-Oz,$(C_FLAGS))\
CXX_FLAGS := $(subst -Os,-Oz,$(CXX_FLAGS))' ncp-uart-hw.Makefile
fi

# =========================================
# Compile
# =========================================
echo ""
echo "[4/4] Compiling firmware..."

# Set STUDIO_ADAPTER_PACK_PATH for post-build if commander is available
if command -v commander >/dev/null 2>&1; then
    COMMANDER_DIR=$(dirname $(which commander))
    export STUDIO_ADAPTER_PACK_PATH="${COMMANDER_DIR}"
    export POST_BUILD_EXE="${COMMANDER_DIR}/commander"
    echo "  Using commander for post-build: ${COMMANDER_DIR}"
fi

make -f ncp-uart-hw.Makefile -j$(nproc)

# =========================================
# Copy output files (with version in filename)
# =========================================
echo ""
echo "Copying output files..."
mkdir -p "${OUTPUT_DIR}"

SRC_BASE="build/debug/ncp-uart-hw"
OUT_BASE="ncp-uart-hw-${EMBERZNET_VERSION}"

# Create .gbl file using commander (only file copied to firmware/)
if command -v commander >/dev/null 2>&1; then
    echo "Creating .gbl file..."
    commander gbl create "${OUTPUT_DIR}/${OUT_BASE}.gbl" --app "${SRC_BASE}.s37"
else
    echo "WARNING: commander not found, cannot create .gbl file"
    echo "Other formats available in build/debug/"
fi

# =========================================
# Summary
# =========================================
echo ""
echo "========================================="
echo "  BUILD COMPLETE"
echo "========================================="
echo ""
echo "EmberZNet version: ${EMBERZNET_VERSION}"
echo ""
echo "Firmware size:"
arm-none-eabi-size "${SRC_BASE}.out"
echo ""
echo "Output files:"
echo "  firmware/${OUT_BASE}.gbl  (for UART flashing)"
echo ""
echo "Other formats in build/debug/:"
ls -lh "${SRC_BASE}".{s37,hex,bin} 2>/dev/null || true
echo ""
echo "Flash commands:"
echo "  Via UART:   universal-silabs-flasher --device socket://IP:8888 flash --firmware firmware/${OUT_BASE}.gbl"
echo "  Via J-Link: commander flash firmware/${OUT_BASE}.gbl --device ${TARGET_DEVICE}"
echo ""
