#!/bin/bash
# build_rcp.sh — Build RCP 802.15.4 firmware for EFR32MG1B232F256GM48
#
# This builds an 802.15.4 RCP firmware compatible with zigbeed and cpcd.
# Uses CPC Protocol v5 (native GSDK 4.5.0) for optimal stability.
#
# Prerequisites:
#   - slc (Silicon Labs CLI) in PATH
#   - arm-none-eabi-gcc in PATH
#   - GECKO_SDK environment variable set
#
# Usage:
#   ./build_rcp.sh           # Build firmware
#   ./build_rcp.sh clean     # Clean build directory
#
# Output:
#   firmware/rcp-uart-802154.gbl  (ready to flash via UART/Xmodem)
#   firmware/rcp-uart-802154.s37  (for J-Link/SWD flashing)
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
PROJECT_NAME="rcp-uart-802154"

# Handle clean command
if [ "${1:-}" = "clean" ]; then
    echo "Cleaning build directory..."
    rm -rf "${BUILD_DIR}"
    echo "Done."
    exit 0
fi

echo "========================================="
echo "  RCP 802.15.4 Firmware Builder"
echo "  Target: ${TARGET_DEVICE}"
echo "  CPC Protocol: v5 (GSDK 4.5.0)"
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
    echo "ERROR: slc (Silicon Labs CLI) not found in PATH"
    echo ""
    echo "Setup options:"
    echo "  1. Use Docker: docker run -it --rm -v \$(pwd):/workspace lidl-gateway-builder"
    echo "  2. Native: cd 1-Build-Environment/12-silabs-toolchain && ./install_silabs.sh"
    exit 1
fi
SLC_VERSION=$(slc --version 2>/dev/null | head -1)
echo "slc: ${SLC_VERSION}"

# Check ARM GCC
if ! command -v arm-none-eabi-gcc >/dev/null 2>&1; then
    echo "ERROR: arm-none-eabi-gcc not found in PATH"
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
        echo "ERROR: GECKO_SDK environment variable not set"
        exit 1
    fi
fi

if [ ! -d "${GECKO_SDK}/protocol/openthread" ]; then
    echo "ERROR: Gecko SDK not found or incomplete: ${GECKO_SDK}"
    echo "       OpenThread component required for RCP build"
    exit 1
fi
echo "Gecko SDK: ${GECKO_SDK}"
echo ""

# =========================================
# Prepare build directory
# =========================================
echo "[1/5] Preparing build directory..."
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

# SDK sample directory
SDK_SAMPLE_DIR="${GECKO_SDK}/protocol/openthread/sample-apps/ot-ncp"
SDK_PLATFORM_DIR="${GECKO_SDK}/util/third_party/openthread/src/lib/platform"

# Copy slcp and main.c from patches, other sources from SDK sample
cp "${PATCHES_DIR}/${PROJECT_NAME}.slcp" .
cp "${PATCHES_DIR}/main.c" .              # Patched with RTL8196E boot delay
cp "${SDK_SAMPLE_DIR}/app.c" .
cp "${SDK_SAMPLE_DIR}/app.h" .
cp "${SDK_PLATFORM_DIR}/reset_util.h" .
echo "  - Copied slcp, main.c from patches (RTL8196E delay)"
echo "  - Copied app.c, app.h, reset_util.h from SDK"

# =========================================
# Generate project with slc
# =========================================
echo ""
echo "[2/5] Generating project with slc..."
slc generate ${PROJECT_NAME}.slcp --sdk "${GECKO_SDK}" --with ${TARGET_DEVICE} --force 2>&1 | tail -5

# =========================================
# Apply configuration patches
# =========================================
echo ""
echo "[3/5] Applying configuration..."

# Copy config files for Lidl Gateway
if [ -d "config" ]; then
    cp "${PATCHES_DIR}/sl_cpc_drv_uart_usart_vcom_config.h" config/ 2>/dev/null || true
    cp "${PATCHES_DIR}/sl_cpc_security_config.h" config/ 2>/dev/null || true
    echo "  - Copied UART config (115200 baud, HW flow control, PA0/PA1/PA4/PA5)"
    echo "  - Copied security config (CPC security disabled)"
fi

# =========================================
# Patch Makefile
# =========================================
echo ""
echo "[4/5] Patching Makefile..."
ARM_GCC_DIR=$(dirname $(dirname $(which arm-none-eabi-gcc)))
echo "  - Setting ARM_GCC_DIR to ${ARM_GCC_DIR}"

MAKEFILE="${PROJECT_NAME}.Makefile"
if [ -f "${MAKEFILE}" ]; then
    sed -i "s|^ARM_GCC_DIR_LINUX\s*=.*|ARM_GCC_DIR_LINUX = ${ARM_GCC_DIR}|" "${MAKEFILE}"

    # Add -Oz optimization
    if ! grep -q 'subst -Os,-Oz' "${MAKEFILE}"; then
        echo "  - Adding -Oz optimization"
        sed -i "/-include ${PROJECT_NAME}.project.mak/a\\
\\
# Override optimization flags for maximum size reduction\\
C_FLAGS := \$(subst -Os,-Oz,\$(C_FLAGS))\\
CXX_FLAGS := \$(subst -Os,-Oz,\$(CXX_FLAGS))" "${MAKEFILE}"
    fi
fi

# =========================================
# Compile
# =========================================
echo ""
echo "[5/5] Compiling firmware..."

# Set commander path for post-build if available
if command -v commander >/dev/null 2>&1; then
    COMMANDER_DIR=$(dirname $(which commander))
    export STUDIO_ADAPTER_PACK_PATH="${COMMANDER_DIR}"
    export POST_BUILD_EXE="${COMMANDER_DIR}/commander"
fi

make -f ${PROJECT_NAME}.Makefile -j$(nproc)

# =========================================
# Copy output files
# =========================================
echo ""
echo "Copying output files..."
mkdir -p "${OUTPUT_DIR}"

SRC_BASE="build/debug/${PROJECT_NAME}"
OUT_BASE="${PROJECT_NAME}"

if [ -f "${SRC_BASE}.s37" ]; then
    # Create .gbl file using commander (the only format needed for flashing)
    if command -v commander >/dev/null 2>&1; then
        echo "Creating .gbl file..."
        commander gbl create "${OUTPUT_DIR}/${OUT_BASE}.gbl" --app "${SRC_BASE}.s37"
        echo "  - Created ${OUT_BASE}.gbl"
    else
        echo "WARNING: commander not found, copying .s37 instead"
        cp "${SRC_BASE}.s37" "${OUTPUT_DIR}/${OUT_BASE}.s37"
    fi
fi

# =========================================
# Summary
# =========================================
echo ""
echo "========================================="
echo "  BUILD COMPLETE"
echo "========================================="
echo ""
echo "CPC Protocol Version: 5 (GSDK 4.5.0 native)"
echo ""
echo "Firmware size:"
if [ -f "${SRC_BASE}.out" ]; then
    arm-none-eabi-size "${SRC_BASE}.out"
fi
echo ""
echo "Output file:"
ls -lh "${OUTPUT_DIR}/${OUT_BASE}.gbl" 2>/dev/null || ls -lh "${OUTPUT_DIR}/${OUT_BASE}".*
echo ""
echo "Flash commands:"
echo "  Via UART:   universal-silabs-flasher --device /dev/ttyUSB0 --firmware firmware/${OUT_BASE}.gbl"
echo "  Via J-Link: commander flash firmware/${OUT_BASE}.gbl --device ${TARGET_DEVICE}"
echo ""
echo "Host setup (Linux):"
echo "  1. Build and install cpcd (see cpcd/README.md)"
echo "  2. Build and install zigbeed (see zigbeed-8.2.2/README.md)"
echo "  3. Configure and start with rcp-stack (see rcp-stack/README.md)"
echo "  4. Connect Zigbee2MQTT to /tmp/ttyZ2M with adapter: ember"
echo ""
