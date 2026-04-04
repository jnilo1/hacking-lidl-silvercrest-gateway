#!/bin/sh
# build_otbr.sh — Build OpenThread Border Router (POSIX) with Lexra toolchain (musl 1.2.5) for RTL8196E
#
# ot-br-posix: OpenThread Border Router POSIX implementation
# Source: https://github.com/openthread/ot-br-posix
# License: BSD-3-Clause
#
# Usage:
#   ./build_otbr.sh [branch/tag]
#
# Examples:
#   ./build_otbr.sh              # Default (main branch)
#   ./build_otbr.sh thread-reference-20230706
#
# Note: This is a complex project with many dependencies. This script is meant
# for experimentation and may require adjustments based on your needs.
#
# J. Nilo - Jan 2025

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Project root is 4 levels up: ot-br-posix -> 34-Userdata -> 3-Main-SoC -> project root
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

# Parse branch/tag argument
BRANCH="${1:-main}"
SOURCE_DIR="${SCRIPT_DIR}/ot-br-posix"
BUILD_DIR="${SCRIPT_DIR}/build"

echo "========================================="
echo "  BUILDING OT-BR-POSIX"
echo "========================================="
echo ""
echo "Branch/Tag: ${BRANCH}"
echo ""

# Clone or update repository
# Note: We don't use --depth 1 for submodules because they reference specific commits
if [ ! -d "$SOURCE_DIR" ]; then
    echo "==> Cloning ot-br-posix repository..."
    git clone --branch "$BRANCH" https://github.com/openthread/ot-br-posix.git "$SOURCE_DIR"
    cd "$SOURCE_DIR"
    git submodule update --init --recursive
else
    echo "==> Source directory exists, updating..."
    cd "$SOURCE_DIR"
    git fetch origin "$BRANCH"
    git checkout "$BRANCH"
    git submodule update --init --recursive
fi

# Patch REST API JSON keys from camelCase to PascalCase.
# ot-br-posix main switched to camelCase (commit 2e8ccf2b, Sep 2025) but
# Home Assistant's python-otbr-api < 2.9.0 expects PascalCase.
JSON_CPP="${SOURCE_DIR}/src/rest/json.cpp"
if [ -f "$JSON_CPP" ] && grep -q '"activeTimestamp"' "$JSON_CPP"; then
    echo "==> Patching REST JSON keys to PascalCase (HA compatibility)..."
    sed -i \
        -e 's/"activeTimestamp"/"ActiveTimestamp"/g' \
        -e 's/"networkKey"/"NetworkKey"/g' \
        -e 's/"networkName"/"NetworkName"/g' \
        -e 's/"extPanId"/"ExtPanId"/g' \
        -e 's/"meshLocalPrefix"/"MeshLocalPrefix"/g' \
        -e 's/"panId"/"PanId"/g' \
        -e 's/"channel"/"Channel"/g' \
        -e 's/"channelMask"/"ChannelMask"/g' \
        -e 's/"pskc"/"PSKc"/g' \
        -e 's/"securityPolicy"/"SecurityPolicy"/g' \
        -e 's/"seconds"/"Seconds"/g' \
        -e 's/"ticks"/"Ticks"/g' \
        -e 's/"authoritative"/"Authoritative"/g' \
        -e 's/"rotationTime"/"RotationTime"/g' \
        -e 's/"obtainNetworkKey"/"ObtainNetworkKey"/g' \
        -e 's/"nativeCommissioning"/"NativeCommissioning"/g' \
        -e 's/"externalCommissioning"/"ExternalCommissioning"/g' \
        -e 's/"commercialCommissioning"/"CommercialCommissioning"/g' \
        -e 's/"autonomousEnrollment"/"AutonomousEnrollment"/g' \
        -e 's/"networkKeyProvisioning"/"NetworkKeyProvisioning"/g' \
        -e 's/"tobleLink"/"TobleLink"/g' \
        -e 's/"routers"/"Routers"/g' \
        -e 's/"nonCcmRouters"/"NonCcmRouters"/g' \
        -e 's/"pendingTimestamp"/"PendingTimestamp"/g' \
        -e 's/"delay"/"Delay"/g' \
        -e 's/"activeDataset"/"ActiveDataset"/g' \
        "$JSON_CPP"
fi

# Lexra toolchain (musl 1.2.5)
TOOLCHAIN_DIR="${PROJECT_ROOT}/x-tools/mips-lexra-linux-musl"
SYSROOT="${TOOLCHAIN_DIR}/mips-lexra-linux-musl/sysroot"

if [ ! -d "$TOOLCHAIN_DIR" ]; then
    echo "Error: Toolchain not found at ${TOOLCHAIN_DIR}"
    exit 1
fi

if ! command -v mips-lexra-linux-musl-gcc >/dev/null 2>&1; then
    export PATH="${TOOLCHAIN_DIR}/bin:$PATH"
fi
export CROSS_COMPILE="mips-lexra-linux-musl-"
export CC="${CROSS_COMPILE}gcc"
export CXX="${CROSS_COMPILE}g++"
export AR="${CROSS_COMPILE}ar"
export RANLIB="${CROSS_COMPILE}ranlib"
export STRIP="${CROSS_COMPILE}strip"

# Common flags for cross-compilation
export CFLAGS="-Os -fno-stack-protector -Wno-error=maybe-uninitialized -DOPENTHREAD_POSIX_CONFIG_DAEMON_SOCKET_BASENAME='\"/tmp/openthread-%s\"'"
export CXXFLAGS="-Os -fno-stack-protector -Wno-error=maybe-uninitialized -DOPENTHREAD_POSIX_CONFIG_DAEMON_SOCKET_BASENAME='\"/tmp/openthread-%s\"'"
export LDFLAGS="-static -Wl,-z,noexecstack,-z,relro,-z,now"

echo "==> Toolchain: ${TOOLCHAIN_DIR}"
echo "==> CC: ${CC}"
echo "==> CXX: ${CXX}"
echo ""

# Create build directory
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# CMake cross-compilation toolchain file
cat > toolchain-mips-lexra.cmake << 'EOF'
# CMake toolchain file for MIPS Lexra (RTL8196E)
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR mips)

# Toolchain paths (will be substituted)
set(TOOLCHAIN_DIR "$ENV{TOOLCHAIN_DIR}")
set(CMAKE_SYSROOT "${TOOLCHAIN_DIR}/mips-lexra-linux-musl/sysroot")

# Compilers
set(CMAKE_C_COMPILER "${TOOLCHAIN_DIR}/bin/mips-lexra-linux-musl-gcc")
set(CMAKE_CXX_COMPILER "${TOOLCHAIN_DIR}/bin/mips-lexra-linux-musl-g++")
set(CMAKE_AR "${TOOLCHAIN_DIR}/bin/mips-lexra-linux-musl-ar")
set(CMAKE_RANLIB "${TOOLCHAIN_DIR}/bin/mips-lexra-linux-musl-ranlib")
set(CMAKE_STRIP "${TOOLCHAIN_DIR}/bin/mips-lexra-linux-musl-strip")

# Compiler flags
set(CMAKE_C_FLAGS_INIT "-Os -fno-stack-protector -Wno-error=maybe-uninitialized -DOPENTHREAD_POSIX_CONFIG_DAEMON_SOCKET_BASENAME='\"/tmp/openthread-%s\"'")
set(CMAKE_CXX_FLAGS_INIT "-Os -fno-stack-protector -Wno-error=maybe-uninitialized -DOPENTHREAD_POSIX_CONFIG_DAEMON_SOCKET_BASENAME='\"/tmp/openthread-%s\"'")
set(CMAKE_EXE_LINKER_FLAGS_INIT "-static -Wl,-z,noexecstack,-z,relro,-z,now")

# Override link command to handle circular dependencies between static libraries
# This wraps all libraries in --start-group/--end-group so the linker resolves
# circular references automatically (e.g., openthread-ftd <-> openthread-posix)
set(CMAKE_C_LINK_EXECUTABLE
    "<CMAKE_C_COMPILER> <FLAGS> <CMAKE_C_LINK_FLAGS> <LINK_FLAGS> <OBJECTS> -o <TARGET> -Wl,--start-group <LINK_LIBRARIES> -Wl,--end-group")
set(CMAKE_CXX_LINK_EXECUTABLE
    "<CMAKE_CXX_COMPILER> <FLAGS> <CMAKE_CXX_LINK_FLAGS> <LINK_FLAGS> <OBJECTS> -o <TARGET> -Wl,--start-group <LINK_LIBRARIES> -Wl,--end-group")

# Search paths
set(CMAKE_FIND_ROOT_PATH "${CMAKE_SYSROOT}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
EOF

# Substitute TOOLCHAIN_DIR in the toolchain file
sed -i "s|\$ENV{TOOLCHAIN_DIR}|${TOOLCHAIN_DIR}|g" toolchain-mips-lexra.cmake

echo "==> Running CMake configuration..."
echo ""
echo "Note: ot-br-posix has many optional features. Starting with minimal config."
echo "You may need to adjust CMAKE options based on your requirements."
echo ""

# Configure with CMake
# Configuration with Border Agent and built-in mDNS (OpenThread implementation)
# This enables:
#   - Border Agent: for Thread commissioning (Matter/HomeKit compatible)
#   - mDNS/DNS-SD: using OpenThread's built-in implementation (no external deps)
#   - SRP Advertising Proxy: automatic with OTBR_MDNS=openthread
#   - DNS-SD Discovery Proxy: automatic with OTBR_MDNS=openthread
cmake "$SOURCE_DIR" \
    -DCMAKE_TOOLCHAIN_FILE="${BUILD_DIR}/toolchain-mips-lexra.cmake" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_TESTING=OFF \
    -DOTBR_DBUS=OFF \
    -DOTBR_WEB=OFF \
    -DOTBR_REST=ON \
    -DOTBR_MDNS=openthread \
    -DOTBR_BACKBONE_ROUTER=OFF \
    -DOTBR_BORDER_ROUTING=ON \
    -DOTBR_TREL=OFF \
    -DOTBR_NAT64=OFF \
    -DOTBR_DNS_UPSTREAM_QUERY=OFF \
    -DOTBR_BORDER_AGENT=ON \
    -DOT_POSIX_RCP_HDLC_BUS=ON \
    -DOT_FIREWALL=OFF \
    -DOT_CHANNEL_MANAGER=ON \
    -DOT_CHANNEL_MONITOR=ON \
    -DOT_POSIX_SETTINGS_PATH=\"/userdata/thread\" \
    "$@"

echo ""
echo "==> Configuration complete!"
echo ""

# Build
# Note: The toolchain file overrides CMAKE_CXX_LINK_EXECUTABLE to use
# --start-group/--end-group, which resolves circular dependencies between
# static libraries (openthread-ftd <-> openthread-posix, etc.)
echo "==> Building..."
make -j$(nproc)

echo "==> Stripping binaries..."
${STRIP} src/agent/otbr-agent
${STRIP} third_party/openthread/repo/src/posix/ot-ctl

echo ""
echo "========================================="
echo "  BUILD COMPLETE"
echo "========================================="
echo ""
echo "  Binaries:"
ls -lh src/agent/otbr-agent third_party/openthread/repo/src/posix/ot-ctl
echo ""
echo "  Features enabled:"
echo "    - Border Agent (Thread commissioning)"
echo "    - mDNS/DNS-SD (OpenThread built-in)"
echo "    - SRP Advertising Proxy"
echo "    - DNS-SD Discovery Proxy"
echo "    - Border Routing
    - Channel Manager / Monitor"
echo ""
echo "To install on gateway:"
echo "  cat build/src/agent/otbr-agent | ssh root@GATEWAY_IP:8888 'cat > /userdata/usr/bin/otbr-agent && chmod +x /userdata/usr/bin/otbr-agent'"
echo "  cat build/third_party/openthread/repo/src/posix/ot-ctl | ssh root@GATEWAY_IP:8888 'cat > /userdata/usr/bin/ot-ctl && chmod +x /userdata/usr/bin/ot-ctl'"
echo ""
