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
#   ./build_ot_rcp.sh                  # Build firmware at default baud (460800)
#   ./build_ot_rcp.sh 230400           # Build at non-default baud
#   UART_DRIVER=iostream ./build_ot_rcp.sh   # force the UART backend
#   ./build_ot_rcp.sh clean            # Clean build directory
#   ./build_ot_rcp.sh --help           # Show this help
#
# NOTE: 460800 is the practical maximum for OT-RCP (max-tested with otbr-agent
#       per CHANGELOG v3.0.0). Higher bauds are unvalidated.
#
# Output:
#   firmware/ot-rcp-<BAUD>.gbl  (ready to flash via UART/Xmodem)
#   firmware/ot-rcp-<BAUD>.s37  (for J-Link/SWD flashing)
#   A forced (non-default) UART_DRIVER adds a -<driver> suffix; non-lidl
#   BOARD= builds add a -<board> suffix.
#
# J. Nilo - January 2026; baud parameter added April 2026;
#           iostream backend selector July 2026 (#142)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
OUTPUT_DIR="${SCRIPT_DIR}/firmware"
PATCHES_DIR="${SCRIPT_DIR}/patches"

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
PROJECT_NAME="ot-rcp"

# Non-default boards get a filename suffix so their artefacts don't overwrite
# the lidl reference firmware (which keeps its historical name).
[ "${BOARD}" = "lidl" ] && BOARD_SUFFIX="" || BOARD_SUFFIX="-${BOARD}"

# UART driver backend. The Gecko SDK's OT platform abstraction has two,
# selected purely by project component (ot_platform_abstraction_core.slcc):
#   uartdrv  — DMA-first: near-zero CPU per byte, but Silabs' own docs call
#              its XON/XOFF support "partial only" (reaction quantised by
#              DMA-chunk cadence — analysis in discussion #134).
#   iostream — IRQ per byte: the NCP's driver, with COMPLETE software flow
#              control (watermark-driven XOFF/XON emission + inbound honor
#              in sl_iostream_uart.c; binary-safe with LF->CRLF conversion
#              off in our header).
# Auto-selected from the board's flow mode: hw|none -> uartdrv (historical
# default, lidl byte-for-byte unchanged), sw -> iostream (the only backend
# that actually flow-controls a board without RTS/CTS — #142). Override
# with UART_DRIVER=uartdrv|iostream for experiments; a forced non-default
# choice is suffixed into the artefact filename so it can never shadow the
# canonical build (and flash_efr32.sh's exact globs never resolve it).
case "${BOARD_UART_FLOW}" in
    sw) UART_DRIVER_AUTO=iostream ;;
    *)  UART_DRIVER_AUTO=uartdrv  ;;
esac
UART_DRIVER="${UART_DRIVER:-$UART_DRIVER_AUTO}"
case "${UART_DRIVER}" in
    uartdrv|iostream) ;;
    *)  echo "Error: UART_DRIVER='${UART_DRIVER}' (expected uartdrv or iostream)" >&2
        exit 1 ;;
esac
DRIVER_SUFFIX=""
[ "${UART_DRIVER}" != "${UART_DRIVER_AUTO}" ] && DRIVER_SUFFIX="-${UART_DRIVER}"

# Default baud — historical OT-RCP default and tested ceiling.
DEFAULT_BAUD=460800
TESTED_BAUDS="460800"

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
        echo "         Build will proceed but the OT-RCP/otbr-agent path is"
        echo "         only validated at 460800."
        ;;
esac

echo "========================================="
echo "  OpenThread RCP Firmware Builder"
echo "  Board:  ${BOARD} (${BOARD_NAME})"
echo "  Target: ${TARGET_DEVICE}"
echo "  Protocol: Thread 1.3 / Matter"
echo "  Baud:   ${BAUD}"
echo "  UART:   ${UART_DRIVER} driver, flow=${BOARD_UART_FLOW}${DRIVER_SUFFIX:+ (forced)}"
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
if [ "${UART_DRIVER}" = "iostream" ]; then
    # Swap the UART backend: an iostream_usart instance makes the OT platform
    # abstraction compile iostream_uart.c instead of uartdrv_uart.c. The slcp
    # config entries are renamed/re-pointed in lockstep so the project file
    # matches the header applied in [3/4] (which is what the firmware actually
    # compiles against). For a uartdrv build the slcp is untouched.
    IOSTREAM_FLOW_TOK="$(flow_control_token usartHwFlowControlCtsAndRts usartHwFlowControlNone uartFlowControlSoftware)" || exit 1
    sed -i -e 's/- id: uartdrv_usart/- id: iostream_usart/' \
           -e 's/SL_UARTDRV_USART_VCOM_BAUDRATE/SL_IOSTREAM_USART_VCOM_BAUDRATE/' \
           -e 's/name: SL_UARTDRV_USART_VCOM_FLOW_CONTROL_TYPE/name: SL_IOSTREAM_USART_VCOM_FLOW_CONTROL_TYPE/' \
           -e "s/value: uartdrvFlowControlHw/value: ${IOSTREAM_FLOW_TOK}/" \
           -e 's/condition: \[uartdrv_usart\]/condition: [iostream_usart]/' \
           ${PROJECT_NAME}.slcp
    echo "  - Copied slcp (UART backend swapped to iostream_usart), main.c from patches (RTL8196E delay)"
else
    echo "  - Copied slcp, main.c from patches (RTL8196E delay)"
fi
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

# Copy the UART config for the selected backend; the reference pins
# (PA0/PA1/PA4/PA5) come from the patches header, then the selected board's
# routing is applied over them (a no-op for the lidl reference, the override
# path for ported boards).
if [ "${UART_DRIVER}" = "iostream" ]; then
    # Same reference header as the NCP — LF->CRLF conversion off (binary-safe).
    cp "${PATCHES_DIR}/sl_iostream_usart_vcom_config.h" config/
    sed -i "s|^#define SL_IOSTREAM_USART_VCOM_BAUDRATE.*|#define SL_IOSTREAM_USART_VCOM_BAUDRATE              ${BAUD}|" config/sl_iostream_usart_vcom_config.h
    apply_uart_config config/sl_iostream_usart_vcom_config.h \
        SL_IOSTREAM_USART_VCOM usartHwFlowControlCtsAndRts usartHwFlowControlNone uartFlowControlSoftware
    echo "  - Copied IOSTREAM config (baud=${BAUD}, board=${BOARD}, ${BOARD_UART_PERIPHERAL}, flow=${BOARD_UART_FLOW})"
elif [ -f "${PATCHES_DIR}/sl_uartdrv_usart_vcom_config.h" ]; then
    cp "${PATCHES_DIR}/sl_uartdrv_usart_vcom_config.h" config/
    # Substitute the requested baud into the UARTDRV config header
    sed -i "s|^#define SL_UARTDRV_USART_VCOM_BAUDRATE.*|#define SL_UARTDRV_USART_VCOM_BAUDRATE        ${BAUD}|" config/sl_uartdrv_usart_vcom_config.h
    apply_uart_config config/sl_uartdrv_usart_vcom_config.h \
        SL_UARTDRV_USART_VCOM uartdrvFlowControlHw uartdrvFlowControlNone uartdrvFlowControlSw
    echo "  - Copied UARTDRV config (baud=${BAUD}, board=${BOARD}, ${BOARD_UART_PERIPHERAL}, flow=${BOARD_UART_FLOW})"
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
OUT_BASE="${PROJECT_NAME}-${BAUD}${DRIVER_SUFFIX}${BOARD_SUFFIX}"

if [ -f "${SRC_BASE}.s37" ]; then
    # Only remove the specific files we're about to rewrite — preserve other
    # baud variants in firmware/ (the matrix lives here side-by-side).
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
ls -lh "${OUTPUT_DIR}/${OUT_BASE}".{gbl,s37} 2>/dev/null
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
