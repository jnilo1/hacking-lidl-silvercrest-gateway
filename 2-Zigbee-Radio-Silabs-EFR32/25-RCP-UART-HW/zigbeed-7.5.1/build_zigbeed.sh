#!/bin/bash
# build_zigbeed.sh - Build and install zigbeed from Gecko SDK
#
# Portable script for x86_64, ARM64 (Raspberry Pi 4/5), ARM32.
# Uses the Gecko SDK installed in silabs-tools/gecko_sdk.
#
# Prerequisites:
#   - Gecko SDK 4.5.0 installed via 1-Build-Environment/
#   - slc-cli in PATH
#   - libcpc installed (build cpcd first)
#
# Usage:
#   ./build_zigbeed.sh         # Build and install
#   ./build_zigbeed.sh clean   # Clean build directory
#
# J. Nilo - January 2026

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"

# Project paths
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
SILABS_TOOLS="${PROJECT_ROOT}/silabs-tools"
GECKO_SDK="${SILABS_TOOLS}/gecko_sdk"
ZIGBEED_SAMPLE="${GECKO_SDK}/protocol/zigbee/app/zigbeed"

# Handle clean
if [ "${1:-}" = "clean" ]; then
    echo "Cleaning..."
    rm -rf "${BUILD_DIR}"
    exit 0
fi

echo "========================================="
echo "  zigbeed builder"
echo "  Architecture: $(uname -m)"
echo "========================================="

# =========================================
# Check prerequisites
# =========================================

# Check SDK
if [ ! -d "${GECKO_SDK}/protocol/zigbee" ]; then
    echo "ERROR: Gecko SDK not found at ${GECKO_SDK}"
    echo ""
    echo "Install it first:"
    echo "  cd ${PROJECT_ROOT}/1-Build-Environment"
    echo "  ./install_silabs.sh"
    exit 1
fi

# Check slc
if [ -d "${SILABS_TOOLS}/slc_cli" ]; then
    export PATH="${SILABS_TOOLS}/slc_cli:$PATH"
    export JAVA_TOOL_OPTIONS="-Duser.home=${SILABS_TOOLS}"
fi

if ! command -v slc >/dev/null 2>&1; then
    echo "ERROR: slc not found in PATH"
    exit 1
fi

# Check libcpc
if ! ldconfig -p 2>/dev/null | grep -q libcpc; then
    echo "WARNING: libcpc not found. Build cpcd first:"
    echo "  cd ../cpcd && ./build_cpcd.sh"
fi

# =========================================
# Detect architecture
# =========================================
case "$(uname -m)" in
    x86_64)  ARCH="x86-64" ;;
    aarch64) ARCH="arm64v8" ;;
    armv7l)  ARCH="arm32v7" ;;
    i686)    ARCH="i386" ;;
    *)
        echo "ERROR: Unsupported architecture: $(uname -m)"
        exit 1
        ;;
esac

echo "Target libs: ${ARCH}"

# =========================================
# Generate project
# =========================================
echo ""
echo "[1/3] Generating project..."

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

# Copy sample sources
cp "${ZIGBEED_SAMPLE}"/*.c .
cp "${ZIGBEED_SAMPLE}"/*.h .
cp "${ZIGBEED_SAMPLE}/zigbeed.slcp" .

# Trust SDK and generate
slc signature trust --sdk "${GECKO_SDK}" 2>/dev/null || true
slc generate zigbeed.slcp -cp --sdk "${GECKO_SDK}" -o makefile --force 2>&1 | tail -3

# =========================================
# Patch Makefile
# =========================================
echo ""
echo "[2/3] Patching Makefile..."

MAKEFILE="zigbeed.Makefile"

# Create libs patch file
cat > libs_patch.mak << ENDPATCH
####################################################################
# Prebuilt Zigbee libraries (architecture: ${ARCH})
####################################################################
ZIGBEE_LIB_PATH = \$(SDK_PATH)/protocol/zigbee/build/gcc/${ARCH}

LIBS += \\
  \$(ZIGBEE_LIB_PATH)/ncp-cbke-library/release_singlenetwork/libncp-cbke-library.a \\
  \$(ZIGBEE_LIB_PATH)/ncp-gp-library/release_singlenetwork/libncp-gp-library.a \\
  \$(ZIGBEE_LIB_PATH)/ncp-mfglib-library/release_singlenetwork/libncp-mfglib-library.a \\
  \$(ZIGBEE_LIB_PATH)/ncp-pro-library/release_singlenetwork/libncp-pro-library.a \\
  \$(ZIGBEE_LIB_PATH)/ncp-source-route-library/release_singlenetwork/libncp-source-route-library.a \\
  \$(ZIGBEE_LIB_PATH)/ncp-zll-library/release_singlenetwork/libncp-zll-library.a \\
  \$(ZIGBEE_LIB_PATH)/zigbee-cbke-core/release_singlenetwork/libzigbee-cbke-core.a \\
  \$(ZIGBEE_LIB_PATH)/zigbee-dynamic-commissioning/release_singlenetwork/libzigbee-dynamic-commissioning.a \\
  \$(ZIGBEE_LIB_PATH)/zigbee-gp/release_singlenetwork/libzigbee-gp.a \\
  \$(ZIGBEE_LIB_PATH)/zigbee-mfglib/release_singlenetwork/libzigbee-mfglib.a \\
  \$(ZIGBEE_LIB_PATH)/zigbee-ncp-uart/release_singlenetwork/libzigbee-ncp-uart.a \\
  \$(ZIGBEE_LIB_PATH)/zigbee-pro-stack/release_singlenetwork/libzigbee-pro-stack.a \\
  \$(ZIGBEE_LIB_PATH)/zigbee-pro-stack-mac-test-cmds/release_singlenetwork/libzigbee-pro-stack-mac-test-cmds.a \\
  \$(ZIGBEE_LIB_PATH)/zigbee-r22-support/release_singlenetwork/libzigbee-r22-support.a \\
  \$(ZIGBEE_LIB_PATH)/zigbee-r23-support/release_singlenetwork/libzigbee-r23-support.a \\
  \$(ZIGBEE_LIB_PATH)/zigbee-source-route/release_singlenetwork/libzigbee-source-route.a \\
  \$(ZIGBEE_LIB_PATH)/zigbee-xncp/release_singlenetwork/libzigbee-xncp.a \\
  \$(ZIGBEE_LIB_PATH)/zigbee-zll/release_singlenetwork/libzigbee-zll.a
ENDPATCH

# Insert patch after "-include zigbeed.project.mak" line
awk '/-include zigbeed.project.mak/{print; system("cat libs_patch.mak"); next}1' "${MAKEFILE}" > "${MAKEFILE}.tmp"
mv "${MAKEFILE}.tmp" "${MAKEFILE}"
rm libs_patch.mak

echo "  Added 18 prebuilt libraries for ${ARCH}"

# =========================================
# Build
# =========================================
echo ""
echo "[3/3] Building..."

make -f "${MAKEFILE}" -j$(nproc)

# =========================================
# Install
# =========================================
echo ""
echo "Installing to /usr/local/bin..."

sudo cp build/debug/zigbeed /usr/local/bin/
sudo chmod +x /usr/local/bin/zigbeed

echo ""
echo "========================================="
echo "  Done!"
echo "========================================="
echo ""
echo "Usage:"
echo "  zigbeed -p 9999    # Listen on TCP port 9999"
echo ""
echo "Zigbee2MQTT config:"
echo "  serial:"
echo "    port: tcp://localhost:9999"
echo "    adapter: ember"
