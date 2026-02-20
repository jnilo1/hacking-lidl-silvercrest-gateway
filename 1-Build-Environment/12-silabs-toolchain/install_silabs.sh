#!/bin/bash
# install_silabs.sh — Install Silicon Labs slc-cli and Gecko SDK
#
# This script downloads and installs:
#   - slc-cli (Simplicity Commander CLI)
#   - Gecko SDK
#   - Required SDK extensions for Zigbee development
#
# Usage:
#   ./install_silabs.sh [install_dir]
#
# Default install directory: <project>/silabs-tools

set -e

# Configuration
SLC_VERSION="5.11"  # Downloaded version may be newer (auto-updated by Silabs)
GECKO_SDK_VERSION="4.5.0"

# Determine project root (parent of 1-Build-Environment)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Default to project directory, allow override
INSTALL_DIR="${1:-${PROJECT_ROOT}/silabs-tools}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Detect architecture (for ARM GCC toolchain)
ARCH=$(uname -m)
case "$ARCH" in
    x86_64|aarch64) ;;
    *)       error "Unsupported architecture: $ARCH" ;;
esac

# Create install directory
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

info "Installing Silicon Labs tools to: $INSTALL_DIR"

# ============================================================================
# Step 1: Download and install slc-cli
# ============================================================================
info "Downloading slc-cli..."

SLC_URL="https://www.silabs.com/documents/public/software/slc_cli_linux.zip"
SLC_ZIP="slc_cli_linux.zip"

if [ ! -f "$INSTALL_DIR/slc_cli/slc" ]; then
    wget -q --show-progress -O "$SLC_ZIP" "$SLC_URL" || error "Failed to download slc-cli"
    unzip -q -o "$SLC_ZIP"
    rm "$SLC_ZIP"
    chmod +x slc_cli/slc
    info "slc-cli installed"
else
    info "slc-cli already installed, skipping"
fi

# Add to PATH for this session
export PATH="$INSTALL_DIR/slc_cli:$PATH"

# Redirect SimplicityStudio workspace to silabs-tools.
# slc is a Java app; Java reads user.home from /etc/passwd, not $HOME,
# so we must override it via JAVA_TOOL_OPTIONS.
export JAVA_TOOL_OPTIONS="-Duser.home=$INSTALL_DIR"

# Verify installation
slc --version || error "slc-cli installation failed"

# ============================================================================
# Step 2: Install Gecko SDK from GitHub
# ============================================================================
info "Installing Gecko SDK v${GECKO_SDK_VERSION}..."

if [ ! -d "$INSTALL_DIR/gecko_sdk" ]; then
    git clone --depth 1 --branch "v${GECKO_SDK_VERSION}" --progress \
        https://github.com/SiliconLabs/gecko_sdk.git gecko_sdk \
        || error "Failed to download Gecko SDK"
    info "Gecko SDK installed"
else
    info "Gecko SDK already installed, skipping"
fi

# Trust the SDK signature
info "Trusting Gecko SDK signature..."
slc signature trust --sdk "$INSTALL_DIR/gecko_sdk" || warn "Signature trust may have failed (non-critical)"

# ============================================================================
# Step 3: Install ARM GCC toolchain
# ============================================================================
info "Installing ARM GCC toolchain..."

ARM_GCC_VERSION="12.2.rel1"
ARM_GCC_URL="https://developer.arm.com/-/media/Files/downloads/gnu/${ARM_GCC_VERSION}/binrel/arm-gnu-toolchain-${ARM_GCC_VERSION}-${ARCH}-arm-none-eabi.tar.xz"

if [ ! -d "$INSTALL_DIR/arm-gnu-toolchain" ]; then
    wget -q --show-progress -O arm-gcc.tar.xz "$ARM_GCC_URL" || error "Failed to download ARM GCC"
    tar xf arm-gcc.tar.xz
    mv arm-gnu-toolchain-* arm-gnu-toolchain
    rm arm-gcc.tar.xz
    info "ARM GCC toolchain installed"
else
    info "ARM GCC toolchain already installed, skipping"
fi

# ============================================================================
# Step 4: Install Simplicity Commander
# ============================================================================
info "Installing Simplicity Commander..."

if [ ! -d "$INSTALL_DIR/commander" ]; then
    wget -q --show-progress -O commander.zip "https://www.silabs.com/documents/public/software/SimplicityCommander-Linux.zip" || error "Failed to download Commander"
    unzip -q commander.zip
    tar xf SimplicityCommander-Linux/Commander_linux_x86_64_*.tar.bz -C .
    rm -rf commander.zip SimplicityCommander-Linux
    info "Simplicity Commander installed"
else
    info "Simplicity Commander already installed, skipping"
fi

# ============================================================================
# Step 5: Create environment setup script
# ============================================================================
info "Creating environment setup script..."

cat > "$INSTALL_DIR/env.sh" << 'EOF'
# Silicon Labs build environment
# Source this file: source <project>/silabs-tools/env.sh

export SILABS_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$SILABS_HOME/slc_cli:$PATH"
export PATH="$SILABS_HOME/arm-gnu-toolchain/bin:$PATH"
export PATH="$SILABS_HOME/commander:$PATH"
export GECKO_SDK="$SILABS_HOME/gecko_sdk"
export ARM_GCC_DIR="$SILABS_HOME/arm-gnu-toolchain"

# slc is a Java app; Java reads user.home from /etc/passwd, not $HOME.
# Override via JAVA_TOOL_OPTIONS so SimplicityStudio is created in silabs-tools.
export JAVA_TOOL_OPTIONS="-Duser.home=$SILABS_HOME"

echo "Silicon Labs environment loaded:"
echo "  GECKO_SDK=$GECKO_SDK"
echo "  ARM_GCC_DIR=$ARM_GCC_DIR"
echo "  SimplicityStudio workspace: $SILABS_HOME/SimplicityStudio"
echo "  slc version: $(slc --version 2>/dev/null | head -1)"
echo "  commander version: $(commander --version 2>/dev/null | head -1)"
EOF

# ============================================================================
# Done
# ============================================================================
info "Installation complete!"
echo ""
echo "To use the Silicon Labs tools, add to your shell profile:"
echo "  source $INSTALL_DIR/env.sh"
echo ""
echo "Or add these to PATH:"
echo "  export PATH=\"$INSTALL_DIR/slc_cli:\$PATH\""
echo "  export PATH=\"$INSTALL_DIR/arm-gnu-toolchain/bin:\$PATH\""
echo "  export PATH=\"$INSTALL_DIR/commander:\$PATH\""
