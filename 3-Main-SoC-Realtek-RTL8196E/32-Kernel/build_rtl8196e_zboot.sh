#!/bin/bash
# build_rtl8196e_zboot.sh — Build kernel using arch/mips/boot/compressed/ (zboot)
#
# Experimental variant of build_rtl8196e_eth.sh that replaces the external
# lzma-loader with the Linux built-in decompressor (arch/mips/boot/compressed/).
#
# Pipeline comparison:
#   eth build :  vmlinux → objcopy → vmlinux.bin → lzma → vmlinux.bin.lzma
#                       → lzma-loader → loader.bin → cvimg → kernel.img
#   zboot build: vmlinux → (make builds vmlinuz automatically via SYS_SUPPORTS_ZBOOT)
#                       → objcopy → vmlinuz.bin → cvimg → kernel-rtl8196e-zboot.img
#
# Key differences vs build_rtl8196e_eth.sh:
#   - No lzma binary or lzma-loader dependency
#   - CONFIG_KERNEL_LZMA=y injected (same algorithm → direct size/behaviour comparison)
#   - Entry address extracted from vmlinuz ELF header (calc_vmlinuz_load_addr output)
#   - Output: kernel-rtl8196e-zboot.img
#
# Usage:
#   ./build_rtl8196e_zboot.sh              # build + package
#   ./build_rtl8196e_zboot.sh vmlinux      # build vmlinux only
#   ./build_rtl8196e_zboot.sh menuconfig   # open menuconfig
#   ./build_rtl8196e_zboot.sh clean        # remove build tree, rebuild from scratch
#   ./build_rtl8196e_zboot.sh olddefconfig # update .config non-interactively
#   ./build_rtl8196e_zboot.sh --help
#
# Output: kernel-rtl8196e-zboot.img (ready to flash via TFTP)
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
BUILD_DIR="${SCRIPT_DIR}/linux-${KERNEL_VERSION}-rtl8196e-zboot"
OVERLAY_DIR="${SCRIPT_DIR}/linux-${KERNEL_VERSION}-rtl8196e"
KERNEL_CMDLINE="console=ttyS0,115200"

TOOLCHAIN_DIR="${PROJECT_ROOT}/x-tools/mips-lexra-linux-musl"
export PATH="${TOOLCHAIN_DIR}/bin:$PATH"
export ARCH=mips
export CROSS_COMPILE=mips-lexra-linux-musl-
export LOCALVERSION="-rtl8196e-zboot"

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

# Note: no lzma binary or lzma-loader needed — zboot uses the in-tree decompressor.

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
        echo "  (none)        Full build + package -> kernel-rtl8196e-zboot.img"
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
echo "  Linux ${KERNEL_VERSION} — rtl8196e-zboot build (in-tree decompressor)"
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
    echo "Setting up .config (RTL819X=n, RTL8196E_ETH=y, RTL8196E_IMEM=y, KERNEL_LZMA=y)..."
    sed \
        -e 's/^CONFIG_RTL819X=y$/# CONFIG_RTL819X is not set/' \
        -e '/^# CONFIG_RTL819X is not set$/a CONFIG_RTL8196E_ETH=y' \
        "${SCRIPT_DIR}/config-5.10.246-realtek.txt" > .config
    echo "CONFIG_RTL8196E_IMEM=y" >> .config

    # LZMA = same algorithm as the lzma-loader → direct size/behaviour comparison
    echo "CONFIG_KERNEL_LZMA=y" >> .config

    make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE olddefconfig
    echo ""
else
    NEED_OLDDEFCONFIG=false

    # Ensure RTL8196E_ETH=y even if Kconfig was added after initial .config
    if ! grep -q '^CONFIG_RTL8196E_ETH=y' .config; then
        echo "Fixing .config: enabling RTL8196E_ETH..."
        sed -i -e 's/^# CONFIG_RTL8196E_ETH is not set$/CONFIG_RTL8196E_ETH=y/' .config
        if ! grep -q '^CONFIG_RTL8196E_ETH=y' .config; then
            echo "CONFIG_RTL8196E_ETH=y" >> .config
        fi
        NEED_OLDDEFCONFIG=true
    fi

    # Ensure RTL8196E_IMEM=y
    if ! grep -q '^CONFIG_RTL8196E_IMEM=y' .config; then
        echo "Fixing .config: enabling RTL8196E_IMEM..."
        sed -i -e 's/^# CONFIG_RTL8196E_IMEM is not set$/CONFIG_RTL8196E_IMEM=y/' .config
        if ! grep -q '^CONFIG_RTL8196E_IMEM=y' .config; then
            echo "CONFIG_RTL8196E_IMEM=y" >> .config
        fi
        NEED_OLDDEFCONFIG=true
    fi

    # LZMA = same algorithm as the lzma-loader → direct size/behaviour comparison
    if ! grep -q '^CONFIG_KERNEL_LZMA=y' .config; then
        echo "Fixing .config: enabling KERNEL_LZMA..."
        sed -i 's/^# CONFIG_KERNEL_LZMA is not set/CONFIG_KERNEL_LZMA=y/' .config
        if ! grep -q '^CONFIG_KERNEL_LZMA=y' .config; then
            echo "CONFIG_KERNEL_LZMA=y" >> .config
        fi
        NEED_OLDDEFCONFIG=true
    fi

    if [ "$NEED_OLDDEFCONFIG" = true ]; then
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

# ── Packaging (zboot — replaces lzma-loader pipeline) ─────────────────

if [ -z "$CVIMG" ]; then
    echo "WARNING: cvimg not found; skipping image creation."
    echo "  Build cvimg in: ${BUILD_ENV}/"
    exit 0
fi

IMAGE="${SCRIPT_DIR}/kernel-rtl8196e-zboot.img"
rm -f "$IMAGE"

echo "Packaging (zboot)..."

# arch/mips/Makefile copies the final vmlinuz to the build tree root
VMLINUZ_ELF="vmlinuz"

# Verify vmlinuz was built (requires SYS_SUPPORTS_ZBOOT + KERNEL_LZMA in config)
if [ ! -f "$VMLINUZ_ELF" ]; then
    echo "ERROR: vmlinuz not found: $VMLINUZ_ELF"
    echo "  Is CONFIG_SYS_SUPPORTS_ZBOOT active? Run: make ARCH=$ARCH menuconfig"
    exit 1
fi

# Extract entry point address from ELF header.
# calc_vmlinuz_load_addr computes: 0x80000000 + sizeof(vmlinux.bin) + roundup_to_64K
# This is the load address passed to the bootloader via cvimg -e.
VMLINUZ_ENTRY_RAW=$(${CROSS_COMPILE}readelf -h "$VMLINUZ_ELF" \
    | awk '/Entry point address/ {print $NF}')

# Normalise to 32 bits — readelf may sign-extend to 0xffffffff80xxxxxx on MIPS.
# bash arithmetic on x86-64 handles 64-bit integers, so mask off the upper bits.
VMLINUZ_ENTRY=$(printf "0x%08x" $(( ${VMLINUZ_ENTRY_RAW} & 0xffffffff )) 2>/dev/null \
    || python3 -c "print(hex(int('${VMLINUZ_ENTRY_RAW}',16)&0xffffffff))")

echo "  vmlinuz ELF  : $VMLINUZ_ELF"
echo "  vmlinuz entry: $VMLINUZ_ENTRY"

# Convert vmlinuz ELF to flat binary (same flags as vmlinux → vmlinux.bin)
${CROSS_COMPILE}objcopy -O binary \
    -R .reginfo -R .note -R .comment -R .mdebug -S \
    "$VMLINUZ_ELF" vmlinuz.bin

vmlinuz_size=$(stat -c%s vmlinuz.bin)

# Package with cvimg (same signature and burn address as all other builds)
$CVIMG \
    -i vmlinuz.bin \
    -o "$IMAGE" \
    -s "$SIGNATURE" \
    -e "$VMLINUZ_ENTRY" \
    -b "$CVIMG_BURN_ADDR" \
    -a 4k >/dev/null

echo ""
vmlinux_size=$(stat -c%s vmlinux)
img_size=$(stat -c%s "$IMAGE")
echo "  vmlinux      : $(numfmt --to=iec-i --suffix=B $vmlinux_size)"
echo "  vmlinuz.bin  : $(numfmt --to=iec-i --suffix=B $vmlinuz_size)  (decompressor + LZMA kernel)"
echo "  Final image  : $(numfmt --to=iec-i --suffix=B $img_size)"
echo ""
echo "Image ready: $IMAGE"
echo "Flash with:  tftp -m binary 192.168.1.6 -c put kernel-rtl8196e-zboot.img"
