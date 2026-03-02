#!/bin/bash
# build_kernel.sh — Build Linux 5.10.246 for Realtek RTL8196E (Lexra MIPS)
#
# Uses arch/mips/boot/compressed/ (zboot) — no external lzma or lzma-loader.
#
# Supports two Ethernet drivers selectable at build time:
#   - rtl8196e-eth  (new, recommended) — default
#   - rtl819x       (legacy SDK port)  — pass 'legacy' argument
#
# Usage:
#   ./build_kernel.sh              # new driver → kernel.img
#   ./build_kernel.sh legacy       # legacy driver → kernel-legacy.img
#   ./build_kernel.sh clean        # remove build tree, rebuild from scratch
#   ./build_kernel.sh menuconfig   # open menuconfig
#   ./build_kernel.sh olddefconfig # update .config non-interactively
#   ./build_kernel.sh vmlinux      # build vmlinux only (no packaging)
#   ./build_kernel.sh --help
#
# Both drivers use the same patches/ and files/ tree.
# The skbuff.c patch is guarded with #ifdef CONFIG_RTL819X so it is safe
# to apply unconditionally regardless of which driver is selected.
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

TOOLCHAIN_DIR="${PROJECT_ROOT}/x-tools/mips-lexra-linux-musl"
export PATH="${TOOLCHAIN_DIR}/bin:$PATH"
export ARCH=mips
export CROSS_COMPILE=mips-lexra-linux-musl-

# cvimg only — no lzma or lzma-loader needed (zboot uses in-tree decompressor)
BUILD_ENV="${PROJECT_ROOT}/1-Build-Environment/11-realtek-tools"
DOCKER_TOOLS="/home/builder/realtek-tools"

CVIMG=""
for dir in "$BUILD_ENV" "$DOCKER_TOOLS"; do
    [ -x "${dir}/bin/cvimg" ] && CVIMG="${dir}/bin/cvimg" && break
done

CVIMG_BURN_ADDR="0x00020000"
SIGNATURE="cs6c"

# ── Option parsing ─────────────────────────────────────────────────────────

DRIVER="new"          # new | legacy
DO_CLEAN=false
DO_MENUCONFIG=false
DO_OLDDEFCONFIG=false
BUILD_VMLINUX_ONLY=false

for arg in "$@"; do
    case "$arg" in
        legacy)       DRIVER="legacy" ;;
        clean)        DO_CLEAN=true ;;
        menuconfig)   DO_MENUCONFIG=true ;;
        olddefconfig) DO_OLDDEFCONFIG=true ;;
        vmlinux|no-package) BUILD_VMLINUX_ONLY=true ;;
        --help|-h)
            echo "Usage: $0 [legacy] [clean|menuconfig|olddefconfig|vmlinux]"
            echo ""
            echo "  (none)        New driver (rtl8196e-eth) — default"
            echo "  legacy        Legacy driver (rtl819x)"
            echo "  clean         Remove build tree and rebuild from scratch"
            echo "  menuconfig    Run kernel menuconfig"
            echo "  olddefconfig  Update .config non-interactively"
            echo "  vmlinux       Build vmlinux only (no packaging)"
            echo ""
            echo "Output:"
            echo "  new driver  → kernel.img"
            echo "  legacy      → kernel-legacy.img"
            exit 0
            ;;
        *) echo "Unknown option: $arg (use --help)"; exit 1 ;;
    esac
done

# Driver-specific settings
if [ "$DRIVER" = "new" ]; then
    export LOCALVERSION="-rtl8196e-eth"
    BUILD_DIR="${SCRIPT_DIR}/linux-${KERNEL_VERSION}-rtl8196e-eth"
    IMAGE="${SCRIPT_DIR}/kernel.img"
    DRIVER_LABEL="rtl8196e-eth (new, recommended)"
else
    export LOCALVERSION="-rtl8196e"
    BUILD_DIR="${SCRIPT_DIR}/linux-${KERNEL_VERSION}-rtl8196e-legacy"
    IMAGE="${SCRIPT_DIR}/kernel-legacy.img"
    DRIVER_LABEL="rtl819x (legacy)"
fi

echo "==================================================================="
echo "  Linux ${KERNEL_VERSION} — RTL8196E — driver: ${DRIVER_LABEL}"
echo "  Compression: arch/mips/boot/compressed/ (zboot)"
echo "==================================================================="
echo ""

# ── Preflight ──────────────────────────────────────────────────────────────

if ! command -v ${CROSS_COMPILE}gcc >/dev/null 2>&1; then
    echo "ERROR: Lexra toolchain not found: ${CROSS_COMPILE}gcc"
    echo "  Build it: cd ../../1-Build-Environment/10-lexra-toolchain && ./build_toolchain.sh"
    exit 1
fi
echo "Toolchain: $(${CROSS_COMPILE}gcc --version | head -1)"

echo "Build dir: $BUILD_DIR"
echo ""

# ── Clean ──────────────────────────────────────────────────────────────────

if [ "$DO_CLEAN" = true ] && [ -d "$BUILD_DIR" ]; then
    echo "Removing build tree: $BUILD_DIR"
    rm -rf "$BUILD_DIR"
    echo "Done."
    echo ""
fi

# ── Prepare tree ───────────────────────────────────────────────────────────

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

    # Apply ALL patches — skbuff.c is guarded with #ifdef CONFIG_RTL819X
    echo "Applying patches..."
    for patch in "${SCRIPT_DIR}/patches"/*.patch; do
        [ -f "$patch" ] || continue
        echo "  $(basename "$patch")"
        patch -p1 -N < "$patch" 2>/dev/null || echo "    (already applied)"
    done
    echo ""

    # Copy platform files (arch, drivers: gpio, spi, serial, leds, etc.)
    echo "Copying platform files (files/)..."
    cp -r "${SCRIPT_DIR}/files/arch" .
    cp -r "${SCRIPT_DIR}/files/drivers" .
    echo ""
else
    echo "Build tree already present: $BUILD_DIR"
    echo ""
fi

cd "$BUILD_DIR"

# ── Config ─────────────────────────────────────────────────────────────────

if [ ! -f .config ]; then
    echo "Setting up .config (driver: ${DRIVER_LABEL})..."
    if [ "$DRIVER" = "new" ]; then
        sed \
            -e 's/^CONFIG_RTL819X=y$/# CONFIG_RTL819X is not set/' \
            -e '/^# CONFIG_RTL819X is not set$/a CONFIG_RTL8196E_ETH=y' \
            "${SCRIPT_DIR}/config-5.10.246-realtek.txt" > .config
        echo "CONFIG_KERNEL_LZMA=y" >> .config
    else
        # Legacy: ensure RTL8196E_ETH is not set
        sed \
            -e 's/^CONFIG_RTL8196E_ETH=y$/# CONFIG_RTL8196E_ETH is not set/' \
            "${SCRIPT_DIR}/config-5.10.246-realtek.txt" > .config
        echo "CONFIG_KERNEL_LZMA=y" >> .config
    fi
    make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE olddefconfig
    echo ""
else
    NEED_OLDDEFCONFIG=false

    if [ "$DRIVER" = "new" ]; then
        if ! grep -q '^CONFIG_RTL8196E_ETH=y' .config; then
            echo "Fixing .config: enabling RTL8196E_ETH..."
            sed -i 's/^# CONFIG_RTL8196E_ETH is not set$/CONFIG_RTL8196E_ETH=y/' .config
            grep -q '^CONFIG_RTL8196E_ETH=y' .config || echo "CONFIG_RTL8196E_ETH=y" >> .config
            NEED_OLDDEFCONFIG=true
        fi
    else
        if ! grep -q '^CONFIG_RTL819X=y' .config; then
            echo "Fixing .config: enabling RTL819X..."
            sed -i 's/^# CONFIG_RTL819X is not set$/CONFIG_RTL819X=y/' .config
            grep -q '^CONFIG_RTL819X=y' .config || echo "CONFIG_RTL819X=y" >> .config
            NEED_OLDDEFCONFIG=true
        fi
    fi

    if ! grep -q '^CONFIG_KERNEL_LZMA=y' .config; then
        echo "Fixing .config: enabling KERNEL_LZMA..."
        sed -i 's/^# CONFIG_KERNEL_LZMA is not set/CONFIG_KERNEL_LZMA=y/' .config
        grep -q '^CONFIG_KERNEL_LZMA=y' .config || echo "CONFIG_KERNEL_LZMA=y" >> .config
        NEED_OLDDEFCONFIG=true
    fi

    [ "$NEED_OLDDEFCONFIG" = true ] && make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE olddefconfig && echo ""
fi

# ── Special modes ──────────────────────────────────────────────────────────

if [ "$DO_OLDDEFCONFIG" = true ]; then
    make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE olddefconfig
    exit 0
fi

if [ "$DO_MENUCONFIG" = true ]; then
    make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE menuconfig
    exit 0
fi

# ── Build ──────────────────────────────────────────────────────────────────

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

# ── Packaging (zboot) ──────────────────────────────────────────────────────

if [ -z "$CVIMG" ]; then
    echo "WARNING: cvimg not found; skipping image creation."
    echo "  Build cvimg in: ${BUILD_ENV}/"
    exit 0
fi

rm -f "$IMAGE"
echo "Packaging (zboot)..."

VMLINUZ_ELF="vmlinuz"

if [ ! -f "$VMLINUZ_ELF" ]; then
    echo "ERROR: vmlinuz not found — is CONFIG_SYS_SUPPORTS_ZBOOT active?"
    exit 1
fi

# Extract entry point; normalize to 32 bits (readelf may sign-extend on x86-64)
VMLINUZ_ENTRY_RAW=$(${CROSS_COMPILE}readelf -h "$VMLINUZ_ELF" \
    | awk '/Entry point address/ {print $NF}')
VMLINUZ_ENTRY=$(printf "0x%08x" $(( ${VMLINUZ_ENTRY_RAW} & 0xffffffff )) 2>/dev/null \
    || python3 -c "print(hex(int('${VMLINUZ_ENTRY_RAW}',16)&0xffffffff))")

echo "  vmlinuz ELF  : $VMLINUZ_ELF"
echo "  vmlinuz entry: $VMLINUZ_ENTRY"

${CROSS_COMPILE}objcopy -O binary \
    -R .reginfo -R .note -R .comment -R .mdebug -S \
    "$VMLINUZ_ELF" vmlinuz.bin

vmlinuz_size=$(stat -c%s vmlinuz.bin)
vmlinux_size=$(stat -c%s vmlinux)

$CVIMG \
    -i vmlinuz.bin \
    -o "$IMAGE" \
    -s "$SIGNATURE" \
    -e "$VMLINUZ_ENTRY" \
    -b "$CVIMG_BURN_ADDR" \
    -a 4k >/dev/null

img_size=$(stat -c%s "$IMAGE")

echo ""
echo "  vmlinux      : $(numfmt --to=iec-i --suffix=B $vmlinux_size)"
echo "  vmlinuz.bin  : $(numfmt --to=iec-i --suffix=B $vmlinuz_size)  (decompressor + LZMA kernel)"
echo "  Final image  : $(numfmt --to=iec-i --suffix=B $img_size)"
echo ""
echo "Image ready: $IMAGE"
echo "Flash with:  tftp -m binary 192.168.1.6 -c put $(basename "$IMAGE")"
