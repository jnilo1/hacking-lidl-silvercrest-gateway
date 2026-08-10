#!/bin/bash
# build.sh — EXPERIMENTAL: multiprotocol RCP with a Bluetooth HCI endpoint
#
# Builds the SDK's `rcp-uart-802154-blehci` sample — "Multiprotocol
# (OpenThread+Zigbee+BLE) - RCP (UART)" — for the selected BOARD. It is the same
# 802.15.4 RCP `build_rcp.sh` produces, plus FreeRTOS, the Bluetooth controller
# and `bluetooth_hci_cpc`: the radio runs the 802.15.4 stacks and the Bluetooth
# Link Layer concurrently (DMP), and exposes Bluetooth to the host as **HCI over
# CPC** (endpoint 14, SL_CPC_ENDPOINT_BLUETOOTH_RCP).
#
# Host side (all shipped by Silabs, none of it on the gateway — cpcd runs on the
# machine hosting Z2M/HA and reaches the radio over TCP:8888):
#   cpcd -> cpc-hci-bridge (creates /dev/pts_hci) -> hciattach /dev/pts_hci any
#   <baud> noflow -> BlueZ -> Home Assistant sees a local Bluetooth adapter.
#   See app/bluetooth/example_host/bt_host_cpc_hci_bridge/ in the Gecko SDK.
#
# STATUS: EXPERIMENTAL — never run on real hardware, by anyone (discussion #146).
# No prebuilt is committed for it. Expect to debug. Known caveats:
#   - It does not fit on the Lidl's EFR32MG1B (measured: FLASH overflowed by
#     10036 bytes, .heap does not fit in RAM). 512 kB flash / 64 kB RAM parts
#     only — e.g. the Sengled G4's EFR32MG13P732F512IM32 (measured: ~231 kB
#     flash, ~44.6 kB RAM, so it fits with ~19 kB of RAM to spare).
#   - One radio, time-sliced: Bluetooth scanning steals airtime from 802.15.4.
#     Expect Zigbee/Thread latency and retries to rise.
#   - CPC has no software flow control (see build_rcp.sh). On a board without
#     RTS/CTS wiring the link runs unflow-controlled, and a Bluetooth
#     advertisement stream on the same UART is exactly the traffic that overruns
#     the host's 16-byte RX FIFO. Start low, and watch for an `oe:` field on the
#     ttyS1 line of /proc/tty/driver/serial on the gateway.
#   - The Gecko SDK marks the component that carries HCI over CPC
#     (bluetooth_hci_cpc) as `quality: experimental`.
#
# Prerequisites: slc, arm-none-eabi-gcc, GECKO_SDK (same as build_rcp.sh).
#
# Usage:
#   BOARD=sengled-e39-g8c ./build.sh          # default baud (115200)
#   BOARD=sengled-e39-g8c ./build.sh 230400   # another baud
#   ./build.sh clean
#   ./build.sh --help
#
# Output (#145 naming; nothing here is committed):
#   firmware/rcp-uart-802154-blehci-<BAUD>-<flow>[-<board>].gbl   (UART/Xmodem)
#   firmware/rcp-uart-802154-blehci-<BAUD>-<flow>[-<board>].s37   (J-Link/SWD)
#   <flow> = hw|none — CPC has no software flow control, so a sw board is built
#   and named none, exactly as build_rcp.sh does.
#
# J. Nilo - July 2026 (discussion #146)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RCP_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
OUTPUT_DIR="${RCP_DIR}/firmware"
PATCHES_DIR="${RCP_DIR}/patches"

PROJECT_ROOT="$(cd "${RCP_DIR}/../.." && pwd)"
SILABS_TOOLS_DIR="${PROJECT_ROOT}/silabs-tools"

# Board selection — same contract as every other build script here.
BOARDS_DIR="${RCP_DIR}/../boards"
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

TARGET_DEVICE="${BOARD_TARGET_DEVICE:?board.env must set BOARD_TARGET_DEVICE}"
PROJECT_NAME="rcp-uart-802154-blehci"

[ "${BOARD}" = "lidl" ] && BOARD_SUFFIX="" || BOARD_SUFFIX="-${BOARD}"

# Parse help and cleanup before the target-memory gate. These maintenance
# commands must work even when BOARD defaults to the unsupported Lidl part.
DEFAULT_BAUD=115200
ALLOWED_BAUDS="115200 230400 460800"
case "${1:-}" in
    clean)
        echo "Cleaning build directory..."
        rm -rf "${BUILD_DIR}"
        echo "Done."
        exit 0
        ;;
    --help|-h)
        sed -n '2,45p' "$0"
        echo
        echo "Allowed bauds: ${ALLOWED_BAUDS} (none of them validated on hardware)"
        echo "Default baud:  ${DEFAULT_BAUD}"
        exit 0
        ;;
    "") BAUD=${DEFAULT_BAUD} ;;
    *)  BAUD="$1" ;;
esac

# Hard memory gate. Bluetooth + FreeRTOS costs ~105 kB of flash and ~20 kB of RAM
# on top of the plain RCP; Series-1 Config-1 parts (EFR32MG1, 256 kB / 31 kB) are
# below the floor and the link fails — don't waste ten minutes of build finding
# that out. Silabs states the same 512 kB floor for DMP; every Zigbee+BLE DMP
# sample in the SDK is tagged hardware:device:flash:512 + ram:64.
# (The globs match the Series-1 Config-1 families only — EFR32MG1B/P/V — and must
# not swallow EFR32MG13, hence the character class rather than a bare MG1*.)
case "${TARGET_DEVICE}" in
    EFR32MG1[BPV]*|EFR32BG1[BPV]*)
        echo "Error: ${TARGET_DEVICE} cannot hold this firmware." >&2
        echo "       Measured on this SDK: 'region FLASH overflowed by 10036 bytes'" >&2
        echo "       and '.heap will not fit in region RAM' (the part has 256 kB / 31 kB)." >&2
        echo "       Dynamic multiprotocol needs a 512 kB / 64 kB part — e.g. the" >&2
        echo "       Sengled G4's EFR32MG13P732F512IM32 (BOARD=sengled-e39-g8c)." >&2
        exit 1
        ;;
    EFR32MG13*) ;;   # measured to fit
    *)
        echo "WARNING: ${TARGET_DEVICE} is untested for this firmware. It needs at"
        echo "         least 512 kB flash / 64 kB RAM. Build will proceed anyway."
        echo ""
        ;;
esac

# CPC flow-control token: hw → RTS/CTS, none AND sw → none. CPC's framing has no
# XON/XOFF escaping, so software flow control does not exist on this link — the
# same clamp build_rcp.sh applies, for the same reason.
RCP_FLOW_TOK="$(flow_control_token usartHwFlowControlCtsAndRts usartHwFlowControlNone usartHwFlowControlNone)" || exit 1
if [ "${BOARD_UART_FLOW}" = "sw" ]; then
    echo "NOTE: BOARD_UART_FLOW=sw — CPC has no software flow control; building"
    echo "      with flow control NONE. This link therefore has NO flow control"
    echo "      of any kind, and it will now also carry Bluetooth advertisements."
    echo "      Start at the lowest baud that works and watch for 'oe:' on the"
    echo "      gateway's ttyS1 line in /proc/tty/driver/serial."
    echo ""
fi

# Default baud = the SDK sample's own default, deliberately conservative: this
# firmware has never run anywhere, and on a board without RTS/CTS it carries a
# Bluetooth advertisement stream over an unflow-controlled UART. Raise it once
# the link is proven, not before. cpcd rejects non-POSIX bauds (so 460800 caps).
if ! echo "${BAUD}" | grep -qE '^[0-9]+$'; then
    echo "Error: invalid baud '${BAUD}' (must be a positive integer)" >&2
    echo "Allowed bauds: ${ALLOWED_BAUDS}" >&2
    exit 1
fi
case " ${ALLOWED_BAUDS} " in
    *" ${BAUD} "*) ;;
    *)
        echo "WARNING: baud ${BAUD} is outside {${ALLOWED_BAUDS}}. cpcd validates the"
        echo "         baud against the POSIX list and will reject non-standard values"
        echo "         at runtime. Build will proceed anyway."
        ;;
esac

echo "========================================="
echo "  Multiprotocol RCP + Bluetooth HCI"
echo "  ** EXPERIMENTAL — never run on hardware **"
echo "  Board:  ${BOARD} (${BOARD_NAME})"
echo "  Target: ${TARGET_DEVICE}"
echo "  Baud:   ${BAUD}  (flow: ${BOARD_UART_FLOW})"
echo "========================================="
echo ""

# =========================================
# Toolchain
# =========================================
if [ -d "${SILABS_TOOLS_DIR}/slc_cli" ]; then
    export PATH="${SILABS_TOOLS_DIR}/slc_cli:$PATH"
    export PATH="${SILABS_TOOLS_DIR}/arm-gnu-toolchain/bin:$PATH"
    export PATH="${SILABS_TOOLS_DIR}/commander:$PATH"
    export GECKO_SDK="${SILABS_TOOLS_DIR}/gecko_sdk"
    export JAVA_TOOL_OPTIONS="-Duser.home=${SILABS_TOOLS_DIR}"
fi

if ! command -v slc >/dev/null 2>&1; then
    echo "ERROR: slc (Silicon Labs CLI) not found in PATH" >&2
    echo "  Docker: docker run -it --rm -v \$(pwd):/workspace rtl8196e-gateway-builder" >&2
    echo "  Native: cd 1-Build-Environment/12-silabs-toolchain && ./install_silabs.sh" >&2
    exit 1
fi
echo "slc: $(slc --version 2>/dev/null | head -1)"

if ! command -v arm-none-eabi-gcc >/dev/null 2>&1; then
    echo "ERROR: arm-none-eabi-gcc not found in PATH" >&2
    exit 1
fi
echo "ARM GCC: $(arm-none-eabi-gcc --version | head -1)"

if [ -z "${GECKO_SDK:-}" ] || [ ! -d "${GECKO_SDK}/protocol/openthread" ]; then
    echo "ERROR: Gecko SDK not found or incomplete: ${GECKO_SDK:-<unset>}" >&2
    exit 1
fi
echo "Gecko SDK: ${GECKO_SDK}"
echo ""

SDK_SAMPLE_DIR="${GECKO_SDK}/protocol/openthread/sample-apps/ot-ncp"
SDK_PLATFORM_DIR="${GECKO_SDK}/util/third_party/openthread/src/lib/platform"
SDK_SLCP="${SDK_SAMPLE_DIR}/${PROJECT_NAME}.slcp"
if [ ! -f "${SDK_SLCP}" ]; then
    echo "ERROR: ${PROJECT_NAME}.slcp not found in the SDK (${SDK_SAMPLE_DIR})" >&2
    exit 1
fi

# =========================================
# Prepare build directory
# =========================================
echo "[1/5] Preparing build directory..."
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

# The slcp comes from the SDK unmodified (unlike build_rcp.sh, which carries a
# trimmed copy in patches/): this project is the SDK's, and we only re-point the
# two things that are board- or gateway-specific.
cp "${SDK_SLCP}" .
cp "${PATCHES_DIR}/main.c" .              # RTL8196E boot delay (needs udelay)
cp "${SDK_SAMPLE_DIR}/app.c" .
cp "${SDK_SAMPLE_DIR}/app.h" .
cp "${SDK_PLATFORM_DIR}/reset_util.h" .

# 1. our main.c waits 1 s for the RTL8196E's UART — it needs the udelay component
sed -i '/^component:/a\  - id: udelay' "${PROJECT_NAME}.slcp"
# 2. board flow-control token (value sits on the line after the name)
sed -i -E "/SL_CPC_DRV_UART_VCOM_FLOW_CONTROL_TYPE/{n;s|(value: )[A-Za-z0-9]+|\1${RCP_FLOW_TOK}|}" "${PROJECT_NAME}.slcp"
# 3. requested baud, so the project file does not lie about what it produced (#134)
sed -i -E "/SL_CPC_DRV_UART_VCOM_BAUDRATE/{n;s|(value: ).*|\1${BAUD}|}" "${PROJECT_NAME}.slcp"
echo "  - Copied SDK slcp (+udelay, flow=${BOARD_UART_FLOW}, baud=${BAUD})"
echo "  - Copied main.c from patches (RTL8196E boot delay)"
echo "  - Copied app.c, app.h, reset_util.h from SDK"

# =========================================
# Generate project with slc
# =========================================
echo ""
echo "[2/5] Generating project with slc..."
slc generate "${PROJECT_NAME}.slcp" --sdk "${GECKO_SDK}" --with "${TARGET_DEVICE}" --toolchain gcc --force 2>&1 | tail -5

# =========================================
# Apply configuration
# =========================================
echo ""
echo "[3/5] Applying configuration..."
if [ -d "config" ]; then
    # slc generates no VCOM instance config for a bare part (no Silabs board), so
    # the CPC UART header comes from patches/ — the same one build_rcp.sh uses —
    # and the board's routing is then applied over it.
    cp "${PATCHES_DIR}/sl_cpc_drv_uart_usart_vcom_config.h" config/
    cp "${PATCHES_DIR}/sl_cpc_security_config.h" config/
    sed -i "s|^#define SL_CPC_DRV_UART_VCOM_BAUDRATE.*|#define SL_CPC_DRV_UART_VCOM_BAUDRATE                 ${BAUD}|" config/sl_cpc_drv_uart_usart_vcom_config.h
    apply_uart_config config/sl_cpc_drv_uart_usart_vcom_config.h \
        SL_CPC_DRV_UART_VCOM usartHwFlowControlCtsAndRts usartHwFlowControlNone usartHwFlowControlNone
    echo "  - Copied UART config (baud=${BAUD}, board=${BOARD}, ${BOARD_UART_PERIPHERAL}, flow=${BOARD_UART_FLOW})"
    echo "  - Copied security config (CPC security disabled)"
fi

# =========================================
# Patch Makefile
# =========================================
echo ""
echo "[4/5] Patching Makefile..."
ARM_GCC_DIR=$(dirname "$(dirname "$(which arm-none-eabi-gcc)")")
echo "  - Setting ARM_GCC_DIR to ${ARM_GCC_DIR}"

MAKEFILE="${PROJECT_NAME}.Makefile"
if [ -f "${MAKEFILE}" ]; then
    sed -i "s|^ARM_GCC_DIR_LINUX\s*=.*|ARM_GCC_DIR_LINUX = ${ARM_GCC_DIR}|" "${MAKEFILE}"
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
if command -v commander >/dev/null 2>&1; then
    COMMANDER_DIR=$(dirname "$(which commander)")
    export STUDIO_ADAPTER_PACK_PATH="${COMMANDER_DIR}"
    export POST_BUILD_EXE="${COMMANDER_DIR}/commander"
fi

make -f "${MAKEFILE}" -j"$(nproc)"

# =========================================
# Output
# =========================================
echo ""
echo "Copying output files..."
mkdir -p "${OUTPUT_DIR}"

SRC_BASE="build/debug/${PROJECT_NAME}"
FLOW_TAG="${BOARD_UART_FLOW}"
[ "${BOARD_UART_FLOW}" = "sw" ] && FLOW_TAG=none
OUT_BASE="${PROJECT_NAME}-${BAUD}-${FLOW_TAG}${BOARD_SUFFIX}"

if [ -f "${SRC_BASE}.s37" ]; then
    rm -f "${OUTPUT_DIR}/${OUT_BASE}".{s37,gbl,hex,bin} 2>/dev/null
    cp "${SRC_BASE}.s37" "${OUTPUT_DIR}/${OUT_BASE}.s37"
    if command -v commander >/dev/null 2>&1; then
        echo "Creating .gbl file..."
        commander gbl create "${OUTPUT_DIR}/${OUT_BASE}.gbl" --app "${SRC_BASE}.s37"
    else
        echo "WARNING: commander not found, cannot create .gbl file"
    fi
fi

echo ""
echo "========================================="
echo "  BUILD COMPLETE (EXPERIMENTAL FIRMWARE)"
echo "========================================="
echo ""
echo "Firmware size (flash = text+data, RAM = data+bss):"
[ -f "${SRC_BASE}.out" ] && arm-none-eabi-size "${SRC_BASE}.out"
echo ""
echo "Output files:"
ls -lh "${OUTPUT_DIR}/${OUT_BASE}".{gbl,s37} 2>/dev/null
echo ""
echo "Flash it:"
echo "  cd ${PROJECT_ROOT}"
echo "  BOARD=${BOARD} ./flash_efr32.sh -g <gateway-ip> \\"
echo "    --firmware-file 2-Zigbee-Radio-Silabs-EFR32/25-RCP-UART-HW/firmware/${OUT_BASE}.gbl rcp ${BAUD}"
echo "  (flash_efr32.sh does not resolve this firmware by name — it is not a"
echo "   shipped variant — so pass the file explicitly.)"
echo ""
echo "Host side (on the machine running Z2M/HA, where cpcd runs):"
echo "  1. cpcd  -> the radio, over TCP:8888 (as today)"
echo "  2. cpc-hci-bridge  -> creates /dev/pts_hci  (Gecko SDK:"
echo "     app/bluetooth/example_host/bt_host_cpc_hci_bridge/)"
echo "  3. hciattach /dev/pts_hci any ${BAUD} noflow  -> BlueZ gets an HCI controller"
echo "  4. Home Assistant then sees a normal local Bluetooth adapter."
echo ""
echo "Zigbee/Thread keep working through the same CPC link (zigbeed / otbr-agent)."
echo "Watch the gateway for RX overruns: grep ttyS1 /proc/tty/driver/serial | grep oe:"
echo ""
