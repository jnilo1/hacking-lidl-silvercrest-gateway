#!/bin/bash
# install_deps.sh — Install complete build environment
#
# This script installs everything needed to build both Main SoC and Zigbee firmware:
#   1. Installs all required Ubuntu packages
#   2. Builds crosstool-ng and Lexra MIPS toolchain
#   3. Builds Realtek tools (cvimg, lzma)
#   4. Installs Silabs tools (slc-cli, Gecko SDK, ARM GCC, Commander)
#
# After running this script, both build environments are ready.
#
# Tested on: Ubuntu 22.04 LTS, WSL2
#
# J. Nilo - December 2025

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "========================================="
echo "  INSTALL BUILD DEPENDENCIES"
echo "========================================="
echo ""
echo "Project root: ${PROJECT_ROOT}"
echo ""

# Check if running as root or with sudo
if [ "$EUID" -ne 0 ]; then
    echo "This script must be run with sudo:"
    echo "   sudo ./install_deps.sh"
    exit 1
fi

# Get the real user (not root)
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

echo "Installing for user: ${REAL_USER}"
echo ""

echo "Adding i386 architecture (for some legacy tools)..."
dpkg --add-architecture i386
apt-get update -qq

echo ""
echo "Installing packages..."
echo ""

apt-get install -y \
    build-essential \
    bison \
    flex \
    gawk \
    help2man \
    texinfo \
    libtool-bin \
    libncurses5-dev \
    unzip \
    wget \
    curl \
    bzip2 \
    lbzip2 \
    xz-utils \
    zlib1g-dev \
    libc6-i386 \
    zlib1g:i386 \
    git \
    git-lfs \
    bc \
    libssl-dev \
    libelf-dev \
    cpio \
    python3 \
    python3-pip \
    python3-venv \
    squashfs-tools \
    mtd-utils \
    fakeroot \
    tftp-hpa \
    device-tree-compiler \
    rsync \
    pkg-config \
    openjdk-21-jre-headless \
    libgl1 \
    cmake

echo ""
echo "========================================="
echo "  BUILDING CROSSTOOL-NG"
echo "========================================="
echo ""

CT_NG_VERSION="crosstool-ng-1.26.0"
CT_NG_URL="http://crosstool-ng.org/download/crosstool-ng/${CT_NG_VERSION}.tar.bz2"
CT_NG_INSTALL_DIR="/tmp/crosstool-ng-install"

# Build crosstool-ng in /tmp (as regular user)
cd /tmp
if [ ! -f "${CT_NG_VERSION}.tar.bz2" ]; then
    echo "Downloading crosstool-ng..."
    sudo -u "$REAL_USER" wget -q "${CT_NG_URL}"
fi

echo "Extracting crosstool-ng..."
sudo -u "$REAL_USER" rm -rf "${CT_NG_VERSION}"
sudo -u "$REAL_USER" tar xjf "${CT_NG_VERSION}.tar.bz2"

echo "Building crosstool-ng..."
cd "${CT_NG_VERSION}"
sudo -u "$REAL_USER" ./configure --prefix="${CT_NG_INSTALL_DIR}" >/dev/null
sudo -u "$REAL_USER" make -j$(nproc) >/dev/null 2>&1
sudo -u "$REAL_USER" make install >/dev/null

echo "crosstool-ng installed to ${CT_NG_INSTALL_DIR}"
echo ""

echo "========================================="
echo "  ALL DEPENDENCIES INSTALLED"
echo "========================================="
echo ""
echo "Packages installed:"
echo "  - Build essentials: build-essential, bison, flex, gawk, bc"
echo "  - Crosstool-ng: help2man, texinfo, libtool-bin, libncurses5-dev"
echo "  - Kernel build: libssl-dev, libelf-dev, device-tree-compiler"
echo "  - Compression: bzip2, lbzip2, xz-utils, zlib1g-dev"
echo "  - Filesystem: squashfs-tools, mtd-utils, fakeroot, cpio"
echo "  - 32-bit support: libc6-i386, zlib1g:i386"
echo "  - Flashing: tftp-hpa"
echo "  - Silabs tools: openjdk-21-jre-headless, libgl1"
echo "  - cpcd build: cmake"
echo "  - Other: git, git-lfs, wget, curl, unzip, python3, rsync"
echo ""

echo "========================================="
echo "  BUILDING LEXRA TOOLCHAIN"
echo "========================================="
echo ""

# Export variables for build_toolchain.sh
export PATH="${CT_NG_INSTALL_DIR}/bin:$PATH"
export PROJECT_ROOT

# Run build_toolchain.sh as the real user
cd "${SCRIPT_DIR}/10-lexra-toolchain"
sudo -u "$REAL_USER" \
    PATH="${CT_NG_INSTALL_DIR}/bin:$PATH" \
    PROJECT_ROOT="${PROJECT_ROOT}" \
    ./build_toolchain.sh

echo ""
echo "========================================="
echo "  BUILDING REALTEK TOOLS"
echo "========================================="
echo ""

# Build realtek-tools (cvimg, lzma)
cd "${SCRIPT_DIR}/11-realtek-tools"
sudo -u "$REAL_USER" \
    PATH="${PROJECT_ROOT}/x-tools/mips-lexra-linux-musl/bin:$PATH" \
    PROJECT_ROOT="${PROJECT_ROOT}" \
    ./build_tools.sh

echo ""
echo "========================================="
echo "  INSTALLING SILABS TOOLS"
echo "========================================="
echo ""

# Install Silabs tools (slc-cli, Gecko SDK, ARM GCC, Commander)
cd "${SCRIPT_DIR}/12-silabs-toolchain"
sudo -u "$REAL_USER" ./install_silabs.sh

echo ""
echo "========================================="
echo "  SETUP COMPLETE"
echo "========================================="
echo ""
echo "All tools are ready. You can now build:"
echo ""
echo "  Main SoC (RTL8196E):"
echo "    cd ${PROJECT_ROOT}/3-Main-SoC-Realtek-RTL8196E"
echo "    ./build_rtl8196e.sh"
echo ""
echo "  Zigbee firmware (EFR32):"
echo "    cd ${PROJECT_ROOT}/2-Zigbee-Radio-Silabs-EFR32/24-NCP-UART-HW"
echo "    ./build_ncp.sh"
echo ""
