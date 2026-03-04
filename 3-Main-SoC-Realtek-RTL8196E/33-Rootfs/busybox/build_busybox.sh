#!/bin/sh
# build_busybox.sh — Build BusyBox (MIPS) for RTL8196E against musl library
#
# Usage:
#   ./build_busybox.sh [version] [menuconfig]
#
# Examples:
#   ./build_busybox.sh                    # Build with default version (1.37.0)
#   ./build_busybox.sh menuconfig         # Default version + interactive config
#   ./build_busybox.sh 1.36.1             # Build specific version
#   ./build_busybox.sh 1.36.1 menuconfig  # Specific version + interactive config
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
# Patches applied automatically:
#   1. include/libbb.h        - Disable off_t size check (musl MIPS compatibility)
#   2. scripts/generate_BUFSIZ.sh - PAGE_SIZE fallback (cross-compilation fix)
#   3. libbb/update_passwd.c  - Suppress fcntl lock warning (JFFS2 compatibility)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOTFS_PART="${SCRIPT_DIR}/.."
# Project root is 4 levels up: busybox -> 33-Rootfs -> 3-Main-SoC -> project root
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

# Parse arguments
if [ "$1" = "menuconfig" ]; then
  BB_VER="${BB_VER:-1.37.0}"
  MENUCONFIG="menuconfig"
elif [ -n "$1" ] && [ "$2" = "menuconfig" ]; then
  BB_VER="$1"
  MENUCONFIG="menuconfig"
elif [ -n "$1" ]; then
  BB_VER="$1"
  MENUCONFIG=""
else
  BB_VER="${BB_VER:-1.37.0}"
  MENUCONFIG=""
fi

ARCHIVE="busybox-${BB_VER}.tar.bz2"
SRC_DIR="busybox-${BB_VER}"
BASE_CFG="${SCRIPT_DIR}/busybox.config"
VERSION_CFG="${SCRIPT_DIR}/busybox-${BB_VER}.config"
ROOTFS_DIR="${ROOTFS_PART}/skeleton"
JOBS=$(nproc)
PATCH_MARKER="${SRC_DIR}/.patches_applied"

echo "📦 BusyBox version: ${BB_VER}"

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

# Apply patches if needed (musl compatibility + JFFS2 fixes)
if [ ! -f "${PATCH_MARKER}" ] || [ "${NEED_PATCH}" -eq 1 ]; then
  echo "🔧 Applying patches..."
  
  # Patch 1: include/libbb.h - Disable off_t size check
  echo "  → Patch 1/3: include/libbb.h (off_t size check)"
  if grep -q "struct BUG_off_t_size_is_misdetected" "${SRC_DIR}/include/libbb.h"; then
    sed -i '/struct BUG_off_t_size_is_misdetected {/,/};/c\
/* Disabled for OpenWrt musl MIPS toolchain compatibility */\
/*\
struct BUG_off_t_size_is_misdetected {\
\tchar BUG_off_t_size_is_misdetected[sizeof(off_t) == sizeof(uoff_t) ? 1 : -1];\
};\
*/' "${SRC_DIR}/include/libbb.h"
    echo "     ✅ off_t check commented out"
  else
    echo "     ⚠️  Structure BUG_off_t_size_is_misdetected not found"
  fi
  
  # Patch 2: scripts/generate_BUFSIZ.sh - Add PAGE_SIZE fallback
  echo "  → Patch 2/3: scripts/generate_BUFSIZ.sh (PAGE_SIZE fallback)"
  if grep -q 'test x"\$PAGE_SIZE" = x"" && exit 1' "${SRC_DIR}/scripts/generate_BUFSIZ.sh"; then
    # Line 99: Replace exit 1 with PAGE_SIZE="1000"
    sed -i 's/test x"\$PAGE_SIZE" = x"" && exit 1/test x"$PAGE_SIZE" = x"" \&\& PAGE_SIZE="1000"/' \
      "${SRC_DIR}/scripts/generate_BUFSIZ.sh"
    echo "     ✅ PAGE_SIZE fallback added (line 99)"
  else
    echo "     ⚠️  Line 99 already patched or not found"
  fi
  
  if grep -q 'test \$PAGE_SIZE -lt 1024 && exit 1' "${SRC_DIR}/scripts/generate_BUFSIZ.sh"; then
    # Line 102: Replace exit 1 with PAGE_SIZE=4096
    sed -i 's/test \$PAGE_SIZE -lt 1024 && exit 1/test $PAGE_SIZE -lt 1024 \&\& PAGE_SIZE=4096/' \
      "${SRC_DIR}/scripts/generate_BUFSIZ.sh"
    echo "     ✅ PAGE_SIZE=4096 fallback added (line 102)"
  else
    echo "     ⚠️  Line 102 already patched or not found"
  fi

  # Patch 3: libbb/update_passwd.c - Disable fcntl lock warning (JFFS2 doesn't support file locking)
  echo "  → Patch 3/3: libbb/update_passwd.c (JFFS2 fcntl lock warning)"
  if grep -q 'bb_perror_msg("warning: can'"'"'t lock' "${SRC_DIR}/libbb/update_passwd.c"; then
    sed -i '/if (fcntl(old_fd, F_SETLK, \&lock) < 0)/,/bb_perror_msg.*can.*t lock/c\
\tfcntl(old_fd, F_SETLK, \&lock); /* Ignore lock errors - JFFS2 does not support locking */' \
      "${SRC_DIR}/libbb/update_passwd.c"
    echo "     ✅ fcntl lock warning removed for JFFS2"
  else
    echo "     ⚠️  fcntl lock line already patched or not found"
  fi

  # Mark patches as applied
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
