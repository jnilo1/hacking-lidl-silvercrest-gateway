#!/bin/bash
# build_rtl8196e_eth.sh — Build kernel with rtl8196e-eth driver
#
# Like build_kernel.sh, but swaps the legacy rtl819x Ethernet driver
# for the new rtl8196e-eth driver.
#
# Build tree layout:
#   1. Download vanilla Linux 5.10.246
#   2. Apply patches/          (platform support, skbuff.c hook, ...)
#   3. Copy files/             (platform files + legacy rtl819x driver)
#   4. Copy linux-5.10.246-rtl8196e/ overlay ON TOP
#      (new driver, modified Kconfig/Makefile, debug DTS, pre-patched skbuff.c)
#   5. .config: RTL819X=n, RTL8196E_ETH=y
#
# On re-run with existing tree: re-syncs the overlay (step 4) and rebuilds.
# This lets you iterate on driver code in linux-5.10.246-rtl8196e/ and just
# re-run this script to compile + package.
#
# Usage:
#   ./build_rtl8196e_eth.sh              # build + package
#   ./build_rtl8196e_eth.sh vmlinux      # build vmlinux only
#   ./build_rtl8196e_eth.sh menuconfig   # open menuconfig
#   ./build_rtl8196e_eth.sh clean        # remove build tree, rebuild from scratch
#   ./build_rtl8196e_eth.sh olddefconfig # update .config non-interactively
#   ./build_rtl8196e_eth.sh --help
#
# Output: kernel-rtl8196e-eth.img (ready to flash via TFTP)
#
# J. Nilo — February 2026

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

KERNEL_VERSION="5.10.246"
KERNEL_MAJOR="5.x"
KERNEL_TARBALL="linux-${KERNEL_VERSION}.tar.xz"
KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_MAJOR}/${KERNEL_TARBALL}"
VANILLA_DIR="linux-${KERNEL_VERSION}"
BUILD_DIR="${SCRIPT_DIR}/linux-${KERNEL_VERSION}-rtl8196e-eth"
OVERLAY_DIR="${SCRIPT_DIR}/linux-${KERNEL_VERSION}-rtl8196e"
KERNEL_CMDLINE="console=ttyS0,115200"

TOOLCHAIN_DIR="${PROJECT_ROOT}/x-tools/mips-lexra-linux-musl"
export PATH="${TOOLCHAIN_DIR}/bin:$PATH"
export ARCH=mips
export CROSS_COMPILE=mips-lexra-linux-musl-
export LOCALVERSION="-rtl8196e-eth"

# Tools — check multiple locations (workspace or Docker)
BUILD_ENV="${PROJECT_ROOT}/1-Build-Environment/11-realtek-tools"
DOCKER_TOOLS="/home/builder/realtek-tools"

if [ -x "${BUILD_ENV}/bin/cvimg" ]; then
    CVIMG="${BUILD_ENV}/bin/cvimg"
elif [ -x "${DOCKER_TOOLS}/bin/cvimg" ]; then
    CVIMG="${DOCKER_TOOLS}/bin/cvimg"
else
    CVIMG=""
fi

if [ -x "${BUILD_ENV}/bin/lzma" ]; then
    LZMA="${BUILD_ENV}/bin/lzma"
elif [ -x "${DOCKER_TOOLS}/bin/lzma" ]; then
    LZMA="${DOCKER_TOOLS}/bin/lzma"
else
    LZMA=""
fi

if [ -d "${BUILD_ENV}/lzma-loader" ]; then
    LOADER_DIR="${BUILD_ENV}/lzma-loader"
elif [ -d "${DOCKER_TOOLS}/lzma-loader" ]; then
    LOADER_DIR="${DOCKER_TOOLS}/lzma-loader"
else
    LOADER_DIR=""
fi

CVIMG_START_ADDR="0x80c00000"
CVIMG_BURN_ADDR="0x00020000"
SIGNATURE="cs6c"

# Parse options
DO_CLEAN=false
DO_MENUCONFIG=false
DO_OLDDEFCONFIG=false
BUILD_VMLINUX_ONLY=false

case "${1:-}" in
    clean)
        DO_CLEAN=true
        ;;
    menuconfig)
        DO_MENUCONFIG=true
        ;;
    olddefconfig)
        DO_OLDDEFCONFIG=true
        ;;
    vmlinux|no-package)
        BUILD_VMLINUX_ONLY=true
        ;;
    --help|-h)
        echo "Usage: $0 [clean|menuconfig|olddefconfig|vmlinux|no-package]"
        echo ""
        echo "Options:"
        echo "  (none)        Full build + package -> kernel-rtl8196e-eth.img"
        echo "  vmlinux       Build vmlinux only (no packaging)"
        echo "  menuconfig    Run kernel menuconfig"
        echo "  olddefconfig  Update .config non-interactively"
        echo "  clean         Remove build tree and rebuild from scratch"
        echo ""
        echo "Driver source:  ${OVERLAY_DIR}/"
        echo "Build tree:     ${BUILD_DIR}/"
        exit 0
        ;;
    "")
        ;;
    *)
        echo "Unknown option: $1 (use --help)"
        exit 1
        ;;
esac

echo "==================================================================="
echo "  Linux ${KERNEL_VERSION} — rtl8196e-eth driver build"
echo "==================================================================="
echo ""

# ── Preflight checks ─────────────────────────────────────────────────

if ! command -v ${CROSS_COMPILE}gcc >/dev/null 2>&1; then
    echo "ERROR: Lexra toolchain not found: ${CROSS_COMPILE}gcc"
    echo "Build it first:  cd ../../1-Build-Environment/10-lexra-toolchain && ./build_toolchain.sh"
    exit 1
fi
echo "Toolchain: $(${CROSS_COMPILE}gcc --version | head -1)"

if [ ! -d "$OVERLAY_DIR" ]; then
    echo "ERROR: overlay dir not found: $OVERLAY_DIR"
    exit 1
fi
echo "Overlay:   $OVERLAY_DIR"
echo "Build dir: $BUILD_DIR"
echo ""

# ── Clean ─────────────────────────────────────────────────────────────

if [ "$DO_CLEAN" = true ]; then
    if [ -d "$BUILD_DIR" ]; then
        echo "Removing build tree..."
        rm -rf "$BUILD_DIR"
        echo "Done."
        echo ""
    fi
fi

# ── Prepare tree (download + patch + files) ──────────────────────────

if [ ! -f "$BUILD_DIR/Makefile" ]; then
    echo "--- Preparing kernel tree ---"
    echo ""

    cd "$SCRIPT_DIR"

    if [ ! -f "$KERNEL_TARBALL" ]; then
        echo "Downloading Linux ${KERNEL_VERSION}..."
        wget -q --show-progress "$KERNEL_URL"
    fi

    echo "Extracting..."
    tar xf "$KERNEL_TARBALL"
    mv "$VANILLA_DIR" "$BUILD_DIR"
    rm -f "$KERNEL_TARBALL"

    cd "$BUILD_DIR"

    # Apply patches (skip skbuff.c hook — only needed by legacy rtl819x driver)
    echo "Applying patches..."
    for patch in "${SCRIPT_DIR}/patches"/*.patch; do
        if [ -f "$patch" ]; then
            case "$(basename "$patch")" in
                *skbuff*) echo "  $(basename "$patch") (SKIPPED — legacy only)"; continue ;;
            esac
            echo "  $(basename "$patch")"
            patch -p1 -N < "$patch" 2>/dev/null || echo "    (already applied)"
        fi
    done
    echo ""

    # Copy platform files (arch, drivers: gpio, spi, serial, leds, etc.)
    echo "Copying platform files (files/)..."
    cp -r "${SCRIPT_DIR}/files/arch" .
    cp -r "${SCRIPT_DIR}/files/drivers" .
    echo ""

    TREE_FRESH=true
else
    echo "Build tree already present."
    echo ""
    TREE_FRESH=false
fi

# ── Sync overlay (always, for iteration) ─────────────────────────────

cd "$BUILD_DIR"

echo "Syncing overlay (linux-5.10.246-rtl8196e/)..."
for subdir in arch drivers net; do
    if [ -d "${OVERLAY_DIR}/${subdir}" ]; then
        cp -r "${OVERLAY_DIR}/${subdir}" .
        echo "  ${subdir}/"
    fi
done
echo ""

# ── Config ────────────────────────────────────────────────────────────

if [ ! -f .config ]; then
    echo "Setting up .config (RTL819X=n, RTL8196E_ETH=y)..."
    sed \
        -e 's/^CONFIG_RTL819X=y$/# CONFIG_RTL819X is not set/' \
        -e '/^# CONFIG_RTL819X is not set$/a CONFIG_RTL8196E_ETH=y' \
        "${SCRIPT_DIR}/config-5.10.246-realtek.txt" > .config
    make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE olddefconfig
    echo ""
else
    # Ensure RTL8196E_ETH=y even if Kconfig was added after initial .config
    if ! grep -q '^CONFIG_RTL8196E_ETH=y' .config; then
        echo "Fixing .config: enabling RTL8196E_ETH..."
        sed -i \
            -e 's/^# CONFIG_RTL8196E_ETH is not set$/CONFIG_RTL8196E_ETH=y/' \
            .config
        # If the option wasn't present at all, append it
        if ! grep -q '^CONFIG_RTL8196E_ETH=y' .config; then
            echo "CONFIG_RTL8196E_ETH=y" >> .config
        fi
        make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE olddefconfig
        echo ""
    fi
fi

# ── Special modes ─────────────────────────────────────────────────────

if [ "$DO_OLDDEFCONFIG" = true ]; then
    make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE olddefconfig
    exit 0
fi

if [ "$DO_MENUCONFIG" = true ]; then
    make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE menuconfig
    exit 0
fi

# ── Build ─────────────────────────────────────────────────────────────

JOBS=$(nproc)
echo "Building with $JOBS parallel jobs..."
echo ""

if ! make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE -j$JOBS; then
    echo ""
    echo "=== BUILD FAILED ==="
    exit 1
fi

echo ""
echo "=== COMPILATION OK ==="
echo ""

if [ "$BUILD_VMLINUX_ONLY" = true ]; then
    ls -lh vmlinux
    exit 0
fi

# ── Packaging ─────────────────────────────────────────────────────────

if [ -z "$CVIMG" ] || [ -z "$LZMA" ] || [ -z "$LOADER_DIR" ]; then
    echo "WARNING: packaging tools not found; skipping image creation."
    echo "  Missing: ${CVIMG:+}${CVIMG:-cvimg }${LZMA:+}${LZMA:-lzma }${LOADER_DIR:+}${LOADER_DIR:-lzma-loader}"
    exit 0
fi

IMAGE="${SCRIPT_DIR}/kernel-rtl8196e-eth.img"
rm -f "$IMAGE"

echo "Packaging..."

${CROSS_COMPILE}objcopy -O binary \
    -R .reginfo -R .note -R .comment \
    -R .mdebug -R .MIPS.abiflags -S \
    vmlinux vmlinux.bin

$LZMA e vmlinux.bin vmlinux.bin.lzma -lc1 -lp2 -pb2 >/dev/null 2>&1

PATH="${TOOLCHAIN_DIR}/bin:$PATH" \
KERNEL_DIR="$BUILD_DIR" \
VMLINUX_DIR="$BUILD_DIR" \
VMLINUX_INCLUDE="$BUILD_DIR/include" \
make -C "$LOADER_DIR" \
    CROSS_COMPILE=$CROSS_COMPILE \
    LOADER_DATA="$BUILD_DIR/vmlinux.bin.lzma" \
    KERNEL_DIR="$BUILD_DIR" \
    KERNEL_CMDLINE="$KERNEL_CMDLINE" \
    clean all

$CVIMG \
    -i "$LOADER_DIR/loader.bin" \
    -o "$IMAGE" \
    -s "$SIGNATURE" \
    -e "$CVIMG_START_ADDR" \
    -b "$CVIMG_BURN_ADDR" \
    -a 4k >/dev/null

echo ""
raw_size=$(stat -c%s vmlinux.bin)
lzma_size=$(stat -c%s vmlinux.bin.lzma)
img_size=$(stat -c%s "$IMAGE")
echo "  vmlinux.bin  : $(numfmt --to=iec-i --suffix=B $raw_size)"
echo "  LZMA         : $(numfmt --to=iec-i --suffix=B $lzma_size)"
echo "  Final image  : $(numfmt --to=iec-i --suffix=B $img_size)"
echo ""
echo "Image ready: $IMAGE"
echo "Flash with:  ./flash_kernel.sh"
