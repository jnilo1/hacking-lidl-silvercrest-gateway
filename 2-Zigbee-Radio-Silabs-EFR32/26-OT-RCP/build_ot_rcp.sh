#!/bin/bash
# build_ot_rcp.sh — Build OpenThread RCP firmware for EFR32MG1B232F256GM48
#
# This builds an OpenThread RCP firmware for Thread/Matter networks.
# Compatible with ot-br-posix (OpenThread Border Router).
#
# Prerequisites:
#   - slc (Silicon Labs CLI) in PATH
#   - arm-none-eabi-gcc in PATH
#   - GECKO_SDK environment variable set
#
# Usage:
#   ./build_ot_rcp.sh           # Build firmware
#   ./build_ot_rcp.sh clean     # Clean build directory
#
# Output:
#   firmware/ot-rcp.gbl  (ready to flash via UART/Xmodem)
#   firmware/ot-rcp.s37  (for J-Link/SWD flashing)
#
# J. Nilo - January 2026

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
PROJECT_NAME="ot-rcp"

# Handle clean command
if [ "${1:-}" = "clean" ]; then
    echo "Cleaning build directory..."
    rm -rf "${BUILD_DIR}"
    echo "Done."
    exit 0
fi

echo "========================================="
echo "  OpenThread RCP Firmware Builder"
echo "  Target: ${TARGET_DEVICE}"
echo "  Protocol: Thread 1.3 / Matter"
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
    echo "       OpenThread component required for OT-RCP build"
    exit 1
fi
echo "Gecko SDK: ${GECKO_SDK}"

# Extract OpenThread version
OT_VERSION_FILE="${GECKO_SDK}/protocol/openthread/include/openthread/version.h"
if [ -f "${OT_VERSION_FILE}" ]; then
    OT_VERSION=$(grep 'OPENTHREAD_VERSION_STRING_NO_SHA' "${OT_VERSION_FILE}" | head -1 | sed 's/.*"\(.*\)".*/\1/' || echo "unknown")
    echo "OpenThread: ${OT_VERSION}"
fi
echo ""

# =========================================
# Prepare build directory
# =========================================
echo "[1/4] Preparing build directory..."
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

# Copy slcp and main.c from patches, other sources from SDK sample
SDK_SAMPLE_DIR="${GECKO_SDK}/protocol/openthread/sample-apps/ot-ncp"
SDK_PLATFORM_DIR="${GECKO_SDK}/util/third_party/openthread/src/lib/platform"
cp "${PATCHES_DIR}/${PROJECT_NAME}.slcp" .
cp "${PATCHES_DIR}/main.c" .           # Patched with RTL8196E boot delay
cp "${SDK_SAMPLE_DIR}/app.c" .
cp "${SDK_SAMPLE_DIR}/app.h" .
cp "${SDK_PLATFORM_DIR}/reset_util.h" .
echo "  - Copied slcp, main.c from patches (RTL8196E delay)"
echo "  - Copied app.c, app.h, reset_util.h from SDK"

# =========================================
# Generate project with slc
# =========================================
echo ""
echo "[2/4] Generating project with slc..."
slc generate ${PROJECT_NAME}.slcp --sdk "${GECKO_SDK}" --with ${TARGET_DEVICE} --force 2>&1 | tail -5

# =========================================
# Copy config files and patch Makefile
# =========================================
echo ""
echo "[3/4] Applying configuration..."

# Copy UARTDRV config for Lidl Gateway pins (PA0/PA1/PA4/PA5)
if [ -f "${PATCHES_DIR}/sl_uartdrv_usart_vcom_config.h" ]; then
    cp "${PATCHES_DIR}/sl_uartdrv_usart_vcom_config.h" config/
    echo "  - Copied UARTDRV config (115200 baud, HW flow control, PA0/PA1/PA4/PA5)"
fi

# Copy PTI config: PTI is disabled on this gateway (no debug probe connected).
# The SDK-generated file emits an unconditional #warning even when disabled;
# our patched version guards it with #if MODE != DISABLED.
if [ -f "${PATCHES_DIR}/sl_rail_util_pti_config.h" ]; then
    cp "${PATCHES_DIR}/sl_rail_util_pti_config.h" config/
    echo "  - Copied PTI config (disabled, suppressed spurious warning)"
fi

# Patch Makefile
ARM_GCC_DIR=$(dirname $(dirname $(which arm-none-eabi-gcc)))
echo "  - Setting ARM_GCC_DIR to ${ARM_GCC_DIR}"

MAKEFILE="${PROJECT_NAME}.Makefile"
if [ -f "${MAKEFILE}" ]; then
    sed -i "s|^ARM_GCC_DIR_LINUX\s*=.*|ARM_GCC_DIR_LINUX = ${ARM_GCC_DIR}|" "${MAKEFILE}"

    # Add -Oz optimization and disable unused-label warning (SDK bug workaround)
    if ! grep -q 'subst -Os,-Oz' "${MAKEFILE}"; then
        echo "  - Adding -Oz optimization"
        echo "  - Disabling unused-label warning (SDK bug workaround)"
        echo "  - Enabling Spinel bootloader reset (PLATFORM_BOOTLOADER_MODE)"
        sed -i "/-include ${PROJECT_NAME}.project.mak/a\\
\\
# Override optimization flags for maximum size reduction\\
C_FLAGS := \$(subst -Os,-Oz,\$(C_FLAGS))\\
CXX_FLAGS := \$(subst -Os,-Oz,\$(CXX_FLAGS))\\
# Disable unused-label warning (SDK iostream_uart.c bug)\\
C_FLAGS := \$(subst -Werror=unused-label,,\$(C_FLAGS))\\
# Enable Spinel bootloader reset (SL_CATALOG macro not visible to OT sources)\\
C_DEFS += '-DOPENTHREAD_CONFIG_PLATFORM_BOOTLOADER_MODE_ENABLE=1'" "${MAKEFILE}"
    fi
fi

# =========================================
# Compile
# =========================================
echo ""
echo "[4/4] Compiling firmware..."

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
    cp "${SRC_BASE}.s37" "${OUTPUT_DIR}/${OUT_BASE}.s37"
    cp "${SRC_BASE}.hex" "${OUTPUT_DIR}/${OUT_BASE}.hex" 2>/dev/null || true
    cp "${SRC_BASE}.bin" "${OUTPUT_DIR}/${OUT_BASE}.bin" 2>/dev/null || true

    # Create .gbl file using commander if available
    if command -v commander >/dev/null 2>&1; then
        echo "Creating .gbl file..."
        commander gbl create "${OUTPUT_DIR}/${OUT_BASE}.gbl" --app "${OUTPUT_DIR}/${OUT_BASE}.s37"
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
echo "OpenThread RCP for Thread/Matter networks"
echo ""
echo "Firmware size:"
if [ -f "${SRC_BASE}.out" ]; then
    arm-none-eabi-size "${SRC_BASE}.out"
fi
echo ""
echo "Output files:"
ls -lh "${OUTPUT_DIR}/${OUT_BASE}".*
echo ""
echo "Flash commands:"
echo "  Via UART/Xmodem: Use universal-silabs-flasher"
echo "  Via J-Link:      commander flash firmware/${OUT_BASE}.s37 --device ${TARGET_DEVICE}"
echo ""
echo "Host setup (Linux):"
echo "  For Zigbee: Zigbee2MQTT with adapter: zoh, baudrate: 115200"
echo "  For Thread: ot-br-posix (OpenThread Border Router)"
echo "  See README.md for detailed configuration"
echo ""
