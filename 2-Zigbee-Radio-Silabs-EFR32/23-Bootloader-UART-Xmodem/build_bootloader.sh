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
# Output:
#   firmware/bootloader-uart-xmodem-X.Y.Z.gbl          (for XMODEM upload)
#   firmware/bootloader-uart-xmodem-X.Y.Z.s37          (main stage with CRC, matches .gbl content)
#   firmware/bootloader-uart-xmodem-X.Y.Z-combined.s37 (first_stage + main-crc, for J-Link)
#   Non-lidl BOARD= builds carry a -<board> suffix before the extension.
#
# J. Nilo - December 2025; BOARD= support July 2026 (#143)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
OUTPUT_DIR="${SCRIPT_DIR}/firmware"
PATCHES_DIR="${SCRIPT_DIR}/patches"

# Project root (for auto-detecting silabs-tools)
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SILABS_TOOLS_DIR="${PROJECT_ROOT}/silabs-tools"

# Board selection (BOARD=lidl by default). board.env packages the chip OPN
# and the UART routing to the RTL8196E; see ../boards/README.md. The
# bootloader consumes only the routing subset (apply_uart_routing): its flow
# control is a separate numeric knob kept at 0 for every board — the Xmodem
# path always runs with host-side flow control off.
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

# Bootloader GPIO activation (#148) — opt-in, per board.
#
# The Gecko bootloader decides where to go in enterBootloader() (btl_main.c).
# Without the bootloader_gpio_activation component the GPIO branch is compiled
# out entirely, and the only way in is in-band: a system-request reset issued by
# the running application. An nRST pin pulse is not one — so on a board that
# wires an EFR32 pin to a host GPIO, holding that pin through a reset does
# nothing unless the component is present.
#
# It is added only for a board that declares BOARD_BTL_ACTIVATION_PIN="<port>
# <pin>". The Lidl reference declares none — no such wire exists on that PCB
# (POST-MORTEM-bootloader-recovery.md) — so its project, and its binary, are
# untouched.
BTL_GPIO_PORT=""
BTL_GPIO_PIN=""
if [ -n "${BOARD_BTL_ACTIVATION_PIN:-}" ]; then
    read -r btl_port btl_pin _ <<<"${BOARD_BTL_ACTIVATION_PIN}"
    case "${btl_port}" in
        [A-F]) ;;
        *) echo "Error: BOARD_BTL_ACTIVATION_PIN port must be A-F, got '${btl_port}'" >&2; exit 1 ;;
    esac
    case "${btl_pin}" in
        ''|*[!0-9]*) echo "Error: BOARD_BTL_ACTIVATION_PIN pin must be numeric, got '${btl_pin}'" >&2; exit 1 ;;
    esac
    BTL_GPIO_PORT="gpioPort${btl_port}"
    BTL_GPIO_PIN="${btl_pin}"
fi

# Non-default boards get a filename suffix so their artefacts don't overwrite
# the lidl reference firmware (which keeps its historical name).
[ "${BOARD}" = "lidl" ] && BOARD_SUFFIX="" || BOARD_SUFFIX="-${BOARD}"

# Handle clean command
if [ "${1:-}" = "clean" ]; then
    echo "Cleaning build directory..."
    rm -rf "${BUILD_DIR}"
    echo "Done."
    exit 0
fi

echo "========================================="
echo "  Bootloader-UART-Xmodem Builder"
echo "  Board:  ${BOARD} (${BOARD_NAME})"
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

# Bootloader version.
#
# The version word is  major<<24 | minor<<16 | customer  (btl_config.h). The
# major/minor pair is Silicon Labs' own — "Gecko Bootloader 2.4". The low 16
# bits are the "customer" field, which the SDK exposes as a config option and
# leaves to the integrator. It is ours, and it is load-bearing:
#
# The Gecko bootloader installs a stage-2 upgrade only if the incoming image is
# STRICTLY NEWER than the one running:
#
#     if (imageProps->bootloaderVersion > bootload_getBootloaderVersion())
#         bootload_commitBootloaderUpgrade(...)      // btl_comm_xmodem_common.c
#
# There is no else. A same-version .gbl is skipped in complete silence — yet the
# image has already been staged at BTL_UPGRADE_LOCATION (0x8000), which lives
# *inside* application space, so the app is erased on the way. The result is a
# flash that reports success, wipes the application, and leaves the old
# bootloader in place. That is exactly what happened on the G4 in #148.
#
# The number is per board, because the binary is per board: bump the board's
# BOARD_BTL_CUSTOMER whenever THAT board's bootloader changes, or the new image
# can never reach a unit already running the old one over UART. Boards that did
# not change keep their number — and keep rebuilding byte-identical.
BTL_CUSTOMER="${BOARD_BTL_CUSTOMER:-2}"
case "${BTL_CUSTOMER}" in
    ''|*[!0-9]*) echo "Error: BOARD_BTL_CUSTOMER must be numeric, got '${BTL_CUSTOMER}'" >&2; exit 1 ;;
esac

BTL_CONFIG="${GECKO_SDK}/platform/bootloader/config/btl_config.h"
if [ -f "${BTL_CONFIG}" ]; then
    BTL_MAJOR=$(grep "BOOTLOADER_VERSION_MAIN_MAJOR" "${BTL_CONFIG}" | head -1 | awk '{print $3}')
    BTL_MINOR=$(grep "BOOTLOADER_VERSION_MAIN_MINOR" "${BTL_CONFIG}" | head -1 | awk '{print $3}')
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
# Point the project's device component at the selected board's MCU (the slcp
# pins the lidl part; see build_ncp.sh, #130). For lidl TARGET_DEVICE is the
# same string, so the slcp is byte-identical.
sed -i "s/EFR32MG1B232F256GM48/${TARGET_DEVICE}/g" bootloader-uart-xmodem.slcp
echo "  - Copied project files from patches (device=${TARGET_DEVICE})"

# Pull in the GPIO-activation component for a board that wires the pin. The
# slcp component list is a set, so appending right after the key is enough —
# at column 0, which is how this file indents its list items (two spaces is a
# YAML error here: "Project could not be loaded").
if [ -n "${BTL_GPIO_PORT}" ]; then
    sed -i '/^component:/a\- {id: bootloader_gpio_activation}' bootloader-uart-xmodem.slcp
    grep -q 'bootloader_gpio_activation' bootloader-uart-xmodem.slcp || {
        echo "Error: failed to add bootloader_gpio_activation to the slcp" >&2; exit 1; }
    echo "  - Added bootloader_gpio_activation (${BTL_GPIO_PORT} pin ${BTL_GPIO_PIN})"
fi

# =========================================
# Generate project with slc
# =========================================
echo ""
echo "[2/5] Generating project with slc..."
# --toolchain gcc pins the first-stage template selection: without it slc's
# toolchain resolution is ambiguous and can copy the IAR-built first_stage.s37
# into autogen/ instead of the GCC one (observed 2026-07-08; the two are
# different Silabs binaries for the same chip). Only the -combined.s37 embeds
# the first stage — the .gbl (stage 2) is unaffected either way.
slc generate bootloader-uart-xmodem.slcp --sdk "${GECKO_SDK}" --with ${TARGET_DEVICE} --toolchain gcc --force 2>&1 | tail -3

# =========================================
# Copy config files and patch Makefile
# =========================================
echo ""
echo "[3/5] Applying configuration..."
cp "${PATCHES_DIR}/btl_uart_driver_cfg.h" config/
# Apply the selected board's UART routing (USART instance + TX/RX only — this
# header has no CTS/RTS or flow-control-type defines). A no-op (byte-identical
# header) for the lidl reference, the override path for ported boards.
apply_uart_routing config/btl_uart_driver_cfg.h SL_SERIAL_UART
echo "  - Copied UART config from patches (board=${BOARD})"

# Fill in the GPIO-activation pin. slc copies the SDK's config template, whose
# pin block is deliberately left unset (it emits `#warning "GPIO activation port
# not configured"` and comments the two defines out) because the pin normally
# comes from a board file via the pin tool — and we build against a bare part,
# not a board. So the board's own value is substituted here, and asserted: a
# silent miss would produce a bootloader that ignores the pin, which is exactly
# the bug this fixes (#148).
if [ -n "${BTL_GPIO_PORT}" ]; then
    BTL_CFG="config/btl_gpio_activation_cfg.h"
    [ -f "${BTL_CFG}" ] || { echo "Error: ${BTL_CFG} not generated" >&2; exit 1; }
    sed -i \
        -e '/#warning "GPIO activation port not configured"/d' \
        -e "s|^/*#define SL_BTL_BUTTON_PORT.*|#define SL_BTL_BUTTON_PORT                      ${BTL_GPIO_PORT}|" \
        -e "s|^/*#define SL_BTL_BUTTON_PIN.*|#define SL_BTL_BUTTON_PIN                       ${BTL_GPIO_PIN}|" \
        "${BTL_CFG}"
    grep -qE "^#define SL_BTL_BUTTON_PORT +${BTL_GPIO_PORT}$" "${BTL_CFG}" \
        && grep -qE "^#define SL_BTL_BUTTON_PIN +${BTL_GPIO_PIN}$" "${BTL_CFG}" \
        || { echo "Error: failed to set the GPIO-activation pin in ${BTL_CFG}" >&2; exit 1; }
    # The host drives the line active-low (open-drain), so the bootloader must
    # enter on a LOW level — the SDK default. Assert it rather than assume it.
    grep -qE "^#define SL_GPIO_ACTIVATION_POLARITY +LOW$" "${BTL_CFG}" \
        || { echo "Error: SL_GPIO_ACTIVATION_POLARITY is not LOW in ${BTL_CFG}" >&2; exit 1; }
    echo "  - GPIO activation: ${BTL_GPIO_PORT} pin ${BTL_GPIO_PIN}, active LOW"
fi

# Stamp our customer version into the generated core config. slc copies the
# SDK's template, which hard-codes 2; the value compiled in here is what the
# next bootloader upgrade is compared against, so a silent miss would ship an
# image that can never install itself over UART. Assert, do not assume.
BTL_CORE_CFG="config/btl_core_cfg.h"
[ -f "${BTL_CORE_CFG}" ] || { echo "Error: ${BTL_CORE_CFG} not generated" >&2; exit 1; }
sed -i "s|^#define BOOTLOADER_VERSION_MAIN_CUSTOMER .*|#define BOOTLOADER_VERSION_MAIN_CUSTOMER                    ${BTL_CUSTOMER}|" \
    "${BTL_CORE_CFG}"
grep -qE "^#define BOOTLOADER_VERSION_MAIN_CUSTOMER +${BTL_CUSTOMER}$" "${BTL_CORE_CFG}" \
    || { echo "Error: failed to set BOOTLOADER_VERSION_MAIN_CUSTOMER in ${BTL_CORE_CFG}" >&2; exit 1; }
echo "  - Bootloader version: ${BTL_VERSION} (customer field = ${BTL_CUSTOMER})"

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

# Set STUDIO_ADAPTER_PACK_PATH for post-build if commander is available
if command -v commander >/dev/null 2>&1; then
    COMMANDER_DIR=$(dirname $(which commander))
    export STUDIO_ADAPTER_PACK_PATH="${COMMANDER_DIR}"
    export POST_BUILD_EXE="${COMMANDER_DIR}/commander"
    echo "  Using commander for post-build: ${COMMANDER_DIR}"
fi

make -f bootloader-uart-xmodem.Makefile -j$(nproc)

# =========================================
# Post-build: Generate output files (same as Simplicity Studio)
# =========================================
echo ""
echo "[5/5] Post-build: Generating output files..."

# Create artifact directory (as in Simplicity Studio)
mkdir -p artifact
mkdir -p "${OUTPUT_DIR}"

OUTPUT_NAME="bootloader-uart-xmodem-${BTL_VERSION}${BOARD_SUFFIX}"
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
# Copy to firmware directory (only .gbl and .s37)
# =========================================
echo ""
echo "  Copying artifacts to firmware/..."
# Only remove the files we're about to rewrite — other boards' artefacts
# live side-by-side in firmware/.
rm -f "${OUTPUT_DIR}/${OUTPUT_NAME}".{s37,gbl,hex,bin} \
      "${OUTPUT_DIR}/${OUTPUT_NAME}-combined.s37" 2>/dev/null

# GBL for XMODEM upload
cp "artifact/bootloader-uart-xmodem.gbl" "${OUTPUT_DIR}/${OUTPUT_NAME}.gbl"

# Main stage with CRC (.s37 equivalent of .gbl content)
cp "artifact/bootloader-uart-xmodem-crc.s37" "${OUTPUT_DIR}/${OUTPUT_NAME}.s37"

# Combined (first_stage + main-crc) for J-Link full flash
if [ -f "artifact/bootloader-uart-xmodem-combined.s37" ]; then
    cp "artifact/bootloader-uart-xmodem-combined.s37" "${OUTPUT_DIR}/${OUTPUT_NAME}-combined.s37"
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
echo "Output files:"
ls -lh "${OUTPUT_DIR}/"
echo ""
echo "Flash via J-Link (full bootloader):"
echo "  commander flash firmware/${OUTPUT_NAME}-combined.s37 --device ${TARGET_DEVICE}"
echo ""
echo "Upload via XMODEM (if bootloader already installed):"
echo "  Use firmware/${OUTPUT_NAME}.gbl"
echo ""
echo "Stage 2 only (matches .gbl content):"
echo "  firmware/${OUTPUT_NAME}.s37"
echo ""
