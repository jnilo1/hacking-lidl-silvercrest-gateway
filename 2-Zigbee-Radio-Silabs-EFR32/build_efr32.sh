#!/bin/bash
# build_efr32.sh — Build EFR32 firmware images
#
# Builds all (or selected) EFR32MG1B firmware variants for the
# Lidl Silvercrest Zigbee gateway.
#
# Works both in Docker container and native Ubuntu 22.04 / WSL2.
#
# Usage:
#   ./build_efr32.sh                        # Build all firmware
#   ./build_efr32.sh all                    # Build all firmware
#   ./build_efr32.sh bootloader             # Build bootloader only
#   ./build_efr32.sh ncp                    # Build NCP only
#   ./build_efr32.sh rcp                    # Build RCP only
#   ./build_efr32.sh ot-rcp                 # Build OT-RCP only
#   ./build_efr32.sh router                 # Build Z3 Router only
#   ./build_efr32.sh ncp rcp                # Build NCP + RCP
#
# J. Nilo — March 2026

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Parse arguments
BUILD_BOOTLOADER=0
BUILD_NCP=0
BUILD_RCP=0
BUILD_OT_RCP=0
BUILD_ROUTER=0

if [ $# -eq 0 ] || [ "$1" = "all" ]; then
    BUILD_BOOTLOADER=1
    BUILD_NCP=1
    BUILD_RCP=1
    BUILD_OT_RCP=1
    BUILD_ROUTER=1
else
    for arg in "$@"; do
        case "$arg" in
            bootloader)  BUILD_BOOTLOADER=1 ;;
            ncp)         BUILD_NCP=1 ;;
            rcp)         BUILD_RCP=1 ;;
            ot-rcp)      BUILD_OT_RCP=1 ;;
            router)      BUILD_ROUTER=1 ;;
            --help|-h)
                echo "Usage: $0 [target...]"
                echo ""
                echo "Targets:"
                echo "  all        Build all firmware (default)"
                echo "  bootloader Bootloader UART Xmodem"
                echo "  ncp        NCP UART HW (EmberZNet, EZSP)"
                echo "  rcp        RCP 802.15.4 (CPC Protocol)"
                echo "  ot-rcp     OpenThread RCP (Thread/Matter)"
                echo "  router     Zigbee 3.0 Router"
                echo ""
                echo "Examples:"
                echo "  $0                     # Build all"
                echo "  $0 ncp                 # Build NCP only"
                echo "  $0 rcp ot-rcp          # Build RCP + OT-RCP"
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
echo "  BUILDING EFR32 FIRMWARE"
echo "========================================="
echo ""

# Show what will be built
echo "Targets:"
[ $BUILD_BOOTLOADER -eq 1 ] && echo "  • bootloader"
[ $BUILD_NCP -eq 1 ]        && echo "  • ncp"
[ $BUILD_RCP -eq 1 ]        && echo "  • rcp"
[ $BUILD_OT_RCP -eq 1 ]     && echo "  • ot-rcp"
[ $BUILD_ROUTER -eq 1 ]     && echo "  • router"
echo ""

# Auto-detect silabs-tools in project directory
SILABS_TOOLS_DIR="${PROJECT_ROOT}/silabs-tools"
if [ -d "${SILABS_TOOLS_DIR}/slc_cli" ]; then
    export PATH="${SILABS_TOOLS_DIR}/slc_cli:$PATH"
    export PATH="${SILABS_TOOLS_DIR}/arm-gnu-toolchain/bin:$PATH"
    export PATH="${SILABS_TOOLS_DIR}/commander:$PATH"
    export GECKO_SDK="${SILABS_TOOLS_DIR}/gecko_sdk"
    export JAVA_TOOL_OPTIONS="-Duser.home=${SILABS_TOOLS_DIR}"
fi

# Check slc-cli
if ! command -v slc >/dev/null 2>&1; then
    echo "ERROR: slc-cli not found"
    echo ""
    echo "Install it first:"
    echo "  cd ../1-Build-Environment && sudo ./install_deps.sh"
    exit 1
fi

echo "slc-cli: $(slc --version | head -1)"
echo ""

# Track steps
STEP=0
TOTAL=$((BUILD_BOOTLOADER + BUILD_NCP + BUILD_RCP + BUILD_OT_RCP + BUILD_ROUTER))

# Build bootloader
if [ $BUILD_BOOTLOADER -eq 1 ]; then
    STEP=$((STEP + 1))
    echo "========================================="
    echo "  ${STEP}/${TOTAL} BUILDING BOOTLOADER"
    echo "========================================="
    cd "${SCRIPT_DIR}/23-Bootloader-UART-Xmodem" && ./build_bootloader.sh
    echo ""
fi

# Build NCP
if [ $BUILD_NCP -eq 1 ]; then
    STEP=$((STEP + 1))
    echo "========================================="
    echo "  ${STEP}/${TOTAL} BUILDING NCP"
    echo "========================================="
    cd "${SCRIPT_DIR}/24-NCP-UART-HW" && ./build_ncp.sh
    echo ""
fi

# Build RCP
if [ $BUILD_RCP -eq 1 ]; then
    STEP=$((STEP + 1))
    echo "========================================="
    echo "  ${STEP}/${TOTAL} BUILDING RCP"
    echo "========================================="
    cd "${SCRIPT_DIR}/25-RCP-UART-HW" && ./build_rcp.sh
    echo ""
fi

# Build OT-RCP
if [ $BUILD_OT_RCP -eq 1 ]; then
    STEP=$((STEP + 1))
    echo "========================================="
    echo "  ${STEP}/${TOTAL} BUILDING OT-RCP"
    echo "========================================="
    cd "${SCRIPT_DIR}/26-OT-RCP" && ./build_ot_rcp.sh
    echo ""
fi

# Build Router
if [ $BUILD_ROUTER -eq 1 ]; then
    STEP=$((STEP + 1))
    echo "========================================="
    echo "  ${STEP}/${TOTAL} BUILDING Z3 ROUTER"
    echo "========================================="
    cd "${SCRIPT_DIR}/27-Router" && ./build_router.sh
    echo ""
fi

echo "========================================="
echo "  BUILD COMPLETE"
echo "========================================="
echo ""
echo "Generated firmware:"
[ $BUILD_BOOTLOADER -eq 1 ] && ls -lh "${SCRIPT_DIR}"/23-Bootloader-UART-Xmodem/firmware/*.{gbl,s37} 2>/dev/null || true
[ $BUILD_NCP -eq 1 ]        && ls -lh "${SCRIPT_DIR}"/24-NCP-UART-HW/firmware/*.{gbl,s37} 2>/dev/null || true
[ $BUILD_RCP -eq 1 ]        && ls -lh "${SCRIPT_DIR}"/25-RCP-UART-HW/firmware/*.{gbl,s37} 2>/dev/null || true
[ $BUILD_OT_RCP -eq 1 ]     && ls -lh "${SCRIPT_DIR}"/26-OT-RCP/firmware/*.{gbl,s37} 2>/dev/null || true
[ $BUILD_ROUTER -eq 1 ]     && ls -lh "${SCRIPT_DIR}"/27-Router/firmware/*.{gbl,s37} 2>/dev/null || true
cd "$PROJECT_ROOT"
echo ""
echo "To flash: ./flash_efr32.sh"
echo ""
