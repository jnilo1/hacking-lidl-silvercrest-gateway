#!/bin/bash
# build_router.sh — Build Zigbee 3.0 Router firmware for EFR32MG1B232F256GM48
#
# Works both in Docker container and native Ubuntu 22.04 / WSL2.
#
# Prerequisites:
#   - slc (Silicon Labs CLI) in PATH
#   - arm-none-eabi-gcc in PATH
#   - GECKO_SDK environment variable set
#
# Usage:
#   ./build_router.sh                  # Build firmware at default baud (115200)
#   ./build_router.sh 230400           # Build at non-default baud
#   ./build_router.sh clean            # Clean build directory
#   ./build_router.sh --help           # Show this help
#
# NOTE: the Z3 Router firmware uses UART only for the mini-CLI (text-based
#       management + Gecko Bootloader entry). 115200 is sufficient — higher
#       bauds give no practical benefit, but are accepted for consistency.
#
# Output:
#   firmware/z3-router-<EmberVersion>-<BAUD>-<flow>.gbl  (ready to flash via UART)
#   firmware/z3-router-<EmberVersion>-<BAUD>-<flow>.s37  (for J-Link/SWD flashing)
#   <flow> = hw|sw|none, the board's UART flow-control type (#145). Non-lidl
#   BOARD= builds add a -<board> suffix last.
#
# J. Nilo - January 2026; baud parameter added April 2026; BOARD= support July 2026 (#143)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
OUTPUT_DIR="${SCRIPT_DIR}/firmware"
PATCHES_DIR="${SCRIPT_DIR}/patches"

# Project name
PROJECT_NAME="z3-router"

# Project root (for auto-detecting silabs-tools)
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SILABS_TOOLS_DIR="${PROJECT_ROOT}/silabs-tools"

# Board selection (BOARD=lidl by default). board.env packages the chip OPN
# and the UART routing to the RTL8196E; see ../boards/README.md.
BOARDS_DIR="${SCRIPT_DIR}/../boards"
BOARD="${BOARD:-lidl}"
BOARD_ENV="${BOARDS_DIR}/${BOARD}/board.env"
if [ ! -f "${BOARD_ENV}" ]; then
    echo "Error: unknown BOARD='${BOARD}' (no ${BOARD_ENV})" >&2
    echo "Available boards: $(cd "${BOARDS_DIR}" && ls -d */ 2>/dev/null | tr -d /)" >&2
    exit 1
fi
# shellcheck source=/dev/null
. "${BOARD_ENV}"
. "${BOARDS_DIR}/lib_uart_config.sh"

# Target chip — from the selected board.
TARGET_DEVICE="${BOARD_TARGET_DEVICE:?board.env must set BOARD_TARGET_DEVICE}"

# Non-default boards get a filename suffix so their artefacts don't overwrite
# the lidl reference firmware (which keeps its historical name).
[ "${BOARD}" = "lidl" ] && BOARD_SUFFIX="" || BOARD_SUFFIX="-${BOARD}"

# Default baud — Router CLI is text-based, 115200 is plenty.
DEFAULT_BAUD=115200
TESTED_BAUDS="115200"

case "${1:-}" in
    clean)
        echo "Cleaning build directory..."
        rm -rf "${BUILD_DIR}"
        echo "Done."
        exit 0
        ;;
    --help|-h)
        sed -n '2,16p' "$0"
        echo
        echo "Tested bauds: ${TESTED_BAUDS}"
        echo "Default baud: ${DEFAULT_BAUD}"
        exit 0
        ;;
    "")
        BAUD=${DEFAULT_BAUD}
        ;;
    *)
        BAUD="$1"
        ;;
esac

if ! echo "${BAUD}" | grep -qE '^[0-9]+$'; then
    echo "Error: invalid baud '${BAUD}' (must be a positive integer)" >&2
    echo "Tested bauds: ${TESTED_BAUDS}" >&2
    exit 1
fi
case " ${TESTED_BAUDS} " in
    *" ${BAUD} "*) ;;
    *)
        echo "WARNING: baud ${BAUD} is outside the tested set {${TESTED_BAUDS}}."
        echo "         Router CLI is text-only — higher bauds give no benefit."
        ;;
esac

echo "========================================="
echo "  Zigbee 3.0 Router Firmware Builder"
echo "  Board:  ${BOARD} (${BOARD_NAME})"
echo "  Target: ${TARGET_DEVICE}"
echo "  Baud:   ${BAUD}"
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
    echo "  1. Use Docker: docker run -it --rm -v \$(pwd):/workspace rtl8196e-gateway-builder"
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
cp "${PATCHES_DIR}/${PROJECT_NAME}.slcp" .
cp "${PATCHES_DIR}/main.c" .
cp "${PATCHES_DIR}/app.c" .
cp -r "${PATCHES_DIR}/config" .
# Point the project's device component at the selected board's MCU. The slcp
# pins the lidl part; leaving it on another board pulls a second device family's
# sources (duplicate-symbol link error). For lidl TARGET_DEVICE is the same
# string, so the slcp is byte-identical.
sed -i "s/EFR32MG1B232F256GM48/${TARGET_DEVICE}/g" ${PROJECT_NAME}.slcp
# Point the slcp's flow-control config item at the board's flow type too, so the
# project file matches the VCOM header that apply_uart_config writes below (the
# header is what the firmware compiles against; see build_ncp.sh, #130). lidl
# resolves back to the same hw token, so the slcp stays byte-identical.
ROUTER_FLOW_TOK="$(flow_control_token usartHwFlowControlCtsAndRts usartHwFlowControlNone uartFlowControlSoftware)" || exit 1
sed -i -E "s|(SL_IOSTREAM_USART_VCOM_FLOW_CONTROL_TYPE, value: )[A-Za-z0-9]+|\1${ROUTER_FLOW_TOK}|" ${PROJECT_NAME}.slcp
echo "  - Copied project files from patches (device=${TARGET_DEVICE}, flow=${BOARD_UART_FLOW})"

# =========================================
# Generate project with slc
# =========================================
echo ""
echo "[2/4] Generating project with slc..."
slc generate ${PROJECT_NAME}.slcp --sdk "${GECKO_SDK}" --with ${TARGET_DEVICE} --force 2>&1 | tail -3

# =========================================
# Copy config files and patch Makefile
# =========================================
echo ""
echo "[3/4] Applying configuration..."
cp "${PATCHES_DIR}/sl_iostream_usart_vcom_config.h" config/
cp "${PATCHES_DIR}/sl_rail_util_pti_config.h" config/
cp "${PATCHES_DIR}"/zap-*.h autogen/
cp "${PATCHES_DIR}"/zap-*.c autogen/ 2>/dev/null || true
# Substitute the requested baud into the UART config header
sed -i "s|^#define SL_IOSTREAM_USART_VCOM_BAUDRATE.*|#define SL_IOSTREAM_USART_VCOM_BAUDRATE              ${BAUD}|" config/sl_iostream_usart_vcom_config.h
# Apply the selected board's UART routing — a no-op (byte-identical header)
# for the lidl reference, the override path for ported boards.
apply_uart_config config/sl_iostream_usart_vcom_config.h \
    SL_IOSTREAM_USART_VCOM usartHwFlowControlCtsAndRts usartHwFlowControlNone uartFlowControlSoftware
echo "  - Copied UART (baud=${BAUD}, board=${BOARD}, flow=${BOARD_UART_FLOW}), PTI, and ZAP files from patches"

echo "  Patching Makefile..."
ARM_GCC_DIR=$(dirname $(dirname $(which arm-none-eabi-gcc)))
echo "  - Setting ARM_GCC_DIR to ${ARM_GCC_DIR}"
sed -i "s|^ARM_GCC_DIR_LINUX\s*=.*|ARM_GCC_DIR_LINUX = ${ARM_GCC_DIR}|" ${PROJECT_NAME}.Makefile

# Add -Oz optimization
if ! grep -q 'subst -Os,-Oz' ${PROJECT_NAME}.Makefile; then
    echo "  - Adding -Oz optimization to Makefile"
    sed -i "/-include ${PROJECT_NAME}.project.mak/a\\
\\
# Override optimization flags for maximum size reduction\\
C_FLAGS := \$(subst -Os,-Oz,\$(C_FLAGS))\\
CXX_FLAGS := \$(subst -Os,-Oz,\$(CXX_FLAGS))" ${PROJECT_NAME}.Makefile
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

make -f ${PROJECT_NAME}.Makefile -j$(nproc)

# =========================================
# Copy output files (with version in filename)
# =========================================
echo ""
echo "Copying output files..."
mkdir -p "${OUTPUT_DIR}"

SRC_BASE="build/debug/${PROJECT_NAME}"
# Flow-control type in the filename (#145). The router honours all three modes,
# so the as-built flow == board.env's BOARD_UART_FLOW.
FLOW_TAG="${BOARD_UART_FLOW}"
OUT_BASE="${PROJECT_NAME}-${EMBERZNET_VERSION}-${BAUD}-${FLOW_TAG}${BOARD_SUFFIX}"

# Only remove the specific files we're about to rewrite — preserve other baud
# variants in firmware/ (the matrix lives here side-by-side).
rm -f "${OUTPUT_DIR}/${OUT_BASE}".{s37,gbl,hex,bin} 2>/dev/null

# Copy .s37 for J-Link flashing
cp "${SRC_BASE}.s37" "${OUTPUT_DIR}/${OUT_BASE}.s37"

# Create .gbl file using commander for UART flashing
if command -v commander >/dev/null 2>&1; then
    echo "Creating .gbl file..."
    commander gbl create "${OUTPUT_DIR}/${OUT_BASE}.gbl" --app "${SRC_BASE}.s37"
else
    echo "WARNING: commander not found, cannot create .gbl file"
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
ls -lh "${OUTPUT_DIR}/${OUT_BASE}".{gbl,s37} 2>/dev/null
echo ""
echo "Flash commands:"
echo "  Via UART/Xmodem: universal-silabs-flasher --device tcp://<gateway_ip>:8888 --firmware firmware/${OUT_BASE}.gbl flash"
echo "  Via J-Link:      commander flash firmware/${OUT_BASE}.s37 --device ${TARGET_DEVICE}"
echo ""
echo "Note: The router will automatically join an open Zigbee network."
echo "      Use network steering from the coordinator to enable joining."
echo ""
