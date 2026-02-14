#!/bin/bash
# build_bootloader.sh — Build the RTL8196E bootloader
#
# Original bootloader sources and build flow:
#   Copyright (C) Realtek Semiconductor Corp.
#
# Adapted and simplified for RTL8196E-only builds:
#   J. Nilo - November 2025
#
# Uses the Lexra/musl toolchain from the project x-tools directory.
#
# Two variants are built:
#   - boot:    production flash image (stays in download mode after boot TFTP)
#   - ramtest: RAM-test image with read-back verification of BSS clears
#
# Outputs:
#   boot.bin               - flash image
#   btcode/build/test.bin  - RAM-loadable image for RAM testing
#
# Usage:
#   ./build_bootloader.sh          # build all variants
#   ./build_bootloader.sh clean    # clean all build outputs

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Project root is 2 levels up: 31-Bootloader -> 3-Main-SoC -> project root
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

JUMP_ADDR="${JUMP_ADDR:-0x80500000}"
CROSS_PREFIX="mips-lexra-linux-musl-"

# Toolchain - check project root first, then walk up the repo tree
find_toolchain() {
    # Check in the project root directory (~/hacking-lidl-silvercrest-gateway)
    if [ -d "$PROJECT_ROOT/x-tools/mips-lexra-linux-musl/bin" ]; then
        echo "$PROJECT_ROOT/x-tools/mips-lexra-linux-musl"
        return 0
    fi
    # Fallback: walk up from script directory
    local dir="$SCRIPT_DIR"
    while [ "$dir" != "/" ]; do
        if [ -d "$dir/x-tools/mips-lexra-linux-musl/bin" ]; then
            echo "$dir/x-tools/mips-lexra-linux-musl"
            return 0
        fi
        dir="$(cd "$dir/.." && pwd)"
    done
    return 1
}

TOOLCHAIN_DIR="$(find_toolchain || true)"

if [ -n "$TOOLCHAIN_DIR" ]; then
    export PATH="${TOOLCHAIN_DIR}/bin:$PATH"
fi
export CROSS="${CROSS_PREFIX}"

# --- Checks ----------------------------------------------------------------

if [ -z "$TOOLCHAIN_DIR" ]; then
    echo "Toolchain not found in parent directories (expected x-tools/mips-lexra-linux-musl)"
    echo ""
    echo "Build the toolchain first:"
    echo "  cd ${PROJECT_ROOT}/1-Build-Environment/10-lexra-toolchain"
    echo "  ./build_toolchain.sh"
    exit 1
fi

if ! command -v "${CROSS_PREFIX}gcc" >/dev/null 2>&1; then
    echo "Compiler not found: ${CROSS_PREFIX}gcc"
    exit 1
fi

# --- Clean target -----------------------------------------------------------

do_clean() {
    echo "Cleaning all build outputs..."
    make -C "$SCRIPT_DIR/boot"   CROSS="$CROSS_PREFIX" clean 2>/dev/null || true
    make -C "$SCRIPT_DIR/btcode" CROSS="$CROSS_PREFIX" clean 2>/dev/null || true
    rm -f "$SCRIPT_DIR/boot.bin"
    echo "Done."
}

if [ "${1:-}" = "clean" ]; then
    do_clean
    exit 0
fi

# --- Build ------------------------------------------------------------------

echo "========================================="
echo "  BUILDING RTL8196E BOOTLOADER"
echo "========================================="
echo ""
echo "Toolchain: $TOOLCHAIN_DIR"
echo "Compiler:  $(${CROSS_PREFIX}gcc --version | head -1)"
echo "Jump addr: $JUMP_ADDR"
echo ""

# boot/ must be cleaned between variants because the Makefiles do not
# track CFLAGS changes.

# --- boot variant ---
echo "--- Building boot image ---"
make -C "$SCRIPT_DIR/boot" CROSS="$CROSS_PREFIX" clean
make -C "$SCRIPT_DIR/boot" CROSS="$CROSS_PREFIX" boot JUMP_ADDR="$JUMP_ADDR"
make -C "$SCRIPT_DIR/btcode" CROSS="$CROSS_PREFIX" clean
make -C "$SCRIPT_DIR/btcode" CROSS="$CROSS_PREFIX"
cp -f "$SCRIPT_DIR/btcode/build/boot.bin" "$SCRIPT_DIR/boot.bin"

# --- ramtest variant (btcode CFLAGS change -> clean btcode too) ---
echo ""
echo "--- Building ramtest variant ---"
make -C "$SCRIPT_DIR/boot" CROSS="$CROSS_PREFIX" clean
make -C "$SCRIPT_DIR/boot" CROSS="$CROSS_PREFIX" boot JUMP_ADDR="$JUMP_ADDR" RAMTEST_TRACE=1
make -C "$SCRIPT_DIR/btcode" CROSS="$CROSS_PREFIX" clean
make -C "$SCRIPT_DIR/btcode" CROSS="$CROSS_PREFIX" RAMTEST_TRACE=1

# --- Summary ----------------------------------------------------------------

echo ""
echo "========================================="
echo "  BUILD SUMMARY"
echo "========================================="
echo ""
[ -f "$SCRIPT_DIR/boot.bin" ]              && ls -lh "$SCRIPT_DIR/boot.bin"
[ -f "$SCRIPT_DIR/btcode/build/test.bin" ] && ls -lh "$SCRIPT_DIR/btcode/build/test.bin"
echo ""
echo "Done."
