#!/bin/sh
# build_busybox.sh — Build BusyBox (MIPS) for RTL8196E against musl library
#
# Usage:
#   ./build_busybox.sh [version] [menuconfig] [clean]
#
# Examples:
#   ./build_busybox.sh                    # Build with default version (1.38.0)
#   ./build_busybox.sh menuconfig         # Default version + interactive config
#   ./build_busybox.sh 1.36.1             # Build specific version
#   ./build_busybox.sh 1.36.1 menuconfig  # Specific version + interactive config
#   ./build_busybox.sh clean              # Remove build tree and rebuild
#   BB_VER=1.36.0 ./build_busybox.sh      # Version via environment variable
#
# Configuration files:
#   busybox.config           - Base configuration (used by default for all versions)
#   busybox-X.Y.Z.config     - Version-specific config (optional, overrides base)
#
#   The version-specific config is only created if explicitly saved via menuconfig.
#   This allows customizing options for a specific BusyBox version while keeping
#   a common base configuration.
#
# Patches (applied in alphabetical order from patches/):
#   001-015 alpine-*       - Alpine edge patch set (CVE backports, bugfixes, hardening)
#   900-903 Lexra-*        - Platform adaptations: musl off_t size check, cross-compile
#                            PAGE_SIZE, JFFS2 fcntl lock, FORTIFY_SOURCE write() check
#
# The 800-series path-traversal CVE backports are gone: BusyBox 1.38.0 carries
# them upstream, framework and both tar fixes.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOTFS_PART="${SCRIPT_DIR}/.."
# Project root is 4 levels up: busybox -> 33-Rootfs -> 3-Main-SoC -> project root
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

# Parse arguments
MENUCONFIG=""
DO_CLEAN=false

for arg in "$@"; do
  case "$arg" in
    menuconfig) MENUCONFIG="menuconfig" ;;
    clean)      DO_CLEAN=true ;;
    -h|--help)
      echo "Usage: $0 [version] [menuconfig] [clean]"
      echo ""
      echo "  (none)      Build with default version (1.38.0)"
      echo "  VERSION     Build specific version (e.g. 1.36.1)"
      echo "  menuconfig  Open interactive configuration"
      echo "  clean       Remove build tree and rebuild from scratch"
      echo ""
      echo "  BB_VER=X.Y.Z $0   # version via environment"
      exit 0
      ;;
    *)
      # Treat as version if it looks like a version number
      if echo "$arg" | grep -qE '^[0-9]+\.[0-9]+'; then
        BB_VER="$arg"
      else
        echo "Unknown argument: $arg (use --help)" >&2
        exit 1
      fi
      ;;
  esac
done

BB_VER="${BB_VER:-1.38.0}"

ARCHIVE="busybox-${BB_VER}.tar.bz2"
SRC_DIR="busybox-${BB_VER}"
BASE_CFG="${SCRIPT_DIR}/busybox.config"
VERSION_CFG="${SCRIPT_DIR}/busybox-${BB_VER}.config"
ROOTFS_DIR="${ROOTFS_PART}/skeleton"
JOBS=$(nproc)
PATCH_MARKER="${SRC_DIR}/.patches_applied"

echo "📦 BusyBox version: ${BB_VER}"

# Clean build tree if requested
if [ "$DO_CLEAN" = true ] && [ -d "${SRC_DIR}" ]; then
  echo "🧹 Removing build tree: ${SRC_DIR}"
  rm -rf "${SRC_DIR}"
fi

# Toolchain
TOOLCHAIN_DIR="${PROJECT_ROOT}/x-tools/mips-lexra-linux-musl"
if ! command -v mips-lexra-linux-musl-gcc >/dev/null 2>&1; then
    export PATH="${TOOLCHAIN_DIR}/bin:$PATH"
fi
CROSS_COMPILE=mips-lexra-linux-musl-

# Download and extract if needed
NEED_PATCH=0
if [ ! -d "${SRC_DIR}" ]; then
  if [ ! -f "${SCRIPT_DIR}/${ARCHIVE}" ]; then
    echo "📥 Downloading ${ARCHIVE}..."
    wget -O "${SCRIPT_DIR}/${ARCHIVE}" "https://busybox.net/downloads/${ARCHIVE}"
  else
    echo "✅ Archive ${ARCHIVE} already present"
  fi
  echo "📦 Extracting ${ARCHIVE}..."
  tar -xjf "${SCRIPT_DIR}/${ARCHIVE}"
  NEED_PATCH=1
fi

# Apply patches if needed (Alpine edge set + CVE supplements + Lexra adaptations)
if [ ! -f "${PATCH_MARKER}" ] || [ "${NEED_PATCH}" -eq 1 ]; then
  PATCH_DIR="${SCRIPT_DIR}/patches"
  if [ -d "$PATCH_DIR" ]; then
    echo "🔧 Applying patches from $(basename "$PATCH_DIR")/..."
    for p in "$PATCH_DIR"/*.patch; do
      [ -f "$p" ] || continue
      name=$(basename "$p")
      if patch -d "${SRC_DIR}" -p1 -N < "$p" > /tmp/bb-patch-$$.log 2>&1; then
        echo "  ✅ $name"
      else
        echo "  ❌ $name"
        tail -10 /tmp/bb-patch-$$.log
        rm -f /tmp/bb-patch-$$.log
        exit 1
      fi
    done
    rm -f /tmp/bb-patch-$$.log
  fi
  touch "${PATCH_MARKER}"
  echo "✅ All patches applied successfully"
else
  echo "✅ Patches already applied (${PATCH_MARKER} exists)"
fi

# Build
cd "${SRC_DIR}"
make mrproper

# Configuration priority: version-specific (if exists) > base config > defconfig
if [ -f "${VERSION_CFG}" ]; then
  echo "📁 Using version-specific config: $(basename "${VERSION_CFG}")"
  cp "${VERSION_CFG}" .config
elif [ -f "${BASE_CFG}" ]; then
  echo "📁 Using base config: $(basename "${BASE_CFG}")"
  cp "${BASE_CFG}" .config
else
  echo "⚠️  No configuration file found, creating defconfig..."
  make ARCH=mips CROSS_COMPILE="${CROSS_COMPILE}" defconfig
fi

# Check for new options and update config
echo "🔧 Checking configuration..."
if yes "" | make ARCH=mips CROSS_COMPILE="${CROSS_COMPILE}" oldconfig 2>&1 | grep -q "not set"; then
  echo "⚠️  New options detected, default values applied"
  # Update base config with new options
  cp .config "${BASE_CFG}"
  echo "✅ Base configuration updated"
else
  echo "✅ Configuration compatible"
fi

# Interactive configuration if requested
if [ "$MENUCONFIG" = "menuconfig" ]; then
  echo ""
  echo "🔧 Interactive configuration..."
  make ARCH=mips CROSS_COMPILE="${CROSS_COMPILE}" menuconfig

  echo ""
  echo "Save options:"
  echo "  1) Save to busybox.config (base config for all versions)"
  echo "  2) Save to $(basename "${VERSION_CFG}") (version-specific, overrides base)"
  echo "  3) Don't save"
  echo -n "Your choice [1-3]: "
  read -r SAVE_CHOICE

  case "$SAVE_CHOICE" in
    1)
      cp -f .config "${BASE_CFG}"
      echo "✅ Configuration saved to busybox.config"
      ;;
    2)
      cp -f .config "${VERSION_CFG}"
      echo "✅ Configuration saved to $(basename "${VERSION_CFG}")"
      ;;
    3|*)
      echo "⚠️  Configuration not saved (used for this build only)"
      ;;
  esac
fi

# Remove old symlinks to busybox (in bin, sbin, usr/bin, usr/sbin)
echo "🧹 Removing old symlinks to busybox..."
find "$ROOTFS_DIR/bin" "$ROOTFS_DIR/sbin" "$ROOTFS_DIR/usr/bin" "$ROOTFS_DIR/usr/sbin" \
    -maxdepth 1 -type l 2>/dev/null | while read -r link; do
    target=$(readlink "$link")
    if [ "$target" = "busybox" ] || [ "$target" = "../bin/busybox" ]; then
        echo "  → Removing: $link"
        rm -f "$link"
    fi
done

# Build BusyBox
echo "🛠️  Building BusyBox..."
make CROSS_COMPILE="${CROSS_COMPILE}"

# Second build to optimize COMMON_BUFSIZE
echo "🛠️  Rebuilding to apply optimized buffer size..."
make CROSS_COMPILE="${CROSS_COMPILE}"

# Install BusyBox
echo "📦 Installing BusyBox..."
make CONFIG_PREFIX="${ROOTFS_DIR}" install

# Verify installation
APPLETS_COUNT=$(find "${ROOTFS_DIR}/bin" "${ROOTFS_DIR}/sbin" -type l 2>/dev/null | wc -l)
echo "✅ BusyBox ${BB_VER} installed with ${APPLETS_COUNT} applets in ${ROOTFS_DIR}"

if [ "${APPLETS_COUNT}" -eq 0 ]; then
    echo "⚠️  No applets found! Installation problem."
    echo "📁 Content of ${ROOTFS_DIR}/bin:"
    ls -la "${ROOTFS_DIR}/bin" 2>/dev/null || echo "Directory does not exist"
fi

echo ""
echo "📊 Build summary:"
echo "  • Version: ${BB_VER}"
echo "  • Binary: $(ls -lh busybox 2>/dev/null | awk '{print $5}')"
echo "  • Applets: ${APPLETS_COUNT}"
echo "  • Installation: ${ROOTFS_DIR}"
