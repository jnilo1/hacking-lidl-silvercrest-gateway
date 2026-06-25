# lib/kernel_image.sh — resolve the pre-built kernel image for a (board, kernel)
# pair to the kernel-img/<board>/kernel-<kernel>.img layout under 32-Kernel/.
#
# Sourced by the flash/build scripts that consume a pre-built kernel image:
#   - build_fullflash.sh, create_fullflash.sh         (repo root)
#   - flash_install_rtl8196e.sh                        (repo root, via build_fullflash)
#   - 3-Main-SoC-Realtek-RTL8196E/flash_remote.sh
#   - 3-Main-SoC-Realtek-RTL8196E/32-Kernel/flash_kernel.sh
#
# Single source of truth for the supported boards and kernel lines; keep in
# sync with 32-Kernel/build_kernel.sh, which produces the images into the same
# kernel-img/<board>/kernel-<kernel>.img slots. Intentionally not executable;
# this file is only meant to be sourced.

# Supported values. The default board is lidl and the default kernel line 6.18;
# together they reproduce the historical single-image (kernel-6.18.img) path, so
# a Lidl user who sets neither BOARD nor KERNEL gets exactly the old behaviour.
KERNEL_IMG_KNOWN_BOARDS="lidl sengled-e39-g8c"
KERNEL_IMG_KNOWN_KERNELS="6.18 7.1"
KERNEL_IMG_DEFAULT_BOARD="lidl"
KERNEL_IMG_DEFAULT_KERNEL="6.18"

# Absolute path to the kernel-img/ tree, computed from this file's location
# (lib/ sits at the repo root, 32-Kernel is a fixed relative path). Works
# regardless of the caller's CWD or how deep the sourcing script lives.
_kernel_img_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_IMG_ROOT="$(cd "${_kernel_img_lib_dir}/.." && pwd)/3-Main-SoC-Realtek-RTL8196E/32-Kernel/kernel-img"
unset _kernel_img_lib_dir

# _kernel_img_in_list <needle> <space-separated-haystack> — 0 if present.
_kernel_img_in_list() {
    local needle="$1" item
    for item in $2; do
        [ "$item" = "$needle" ] && return 0
    done
    return 1
}

# kernel_image_validate <board> <kernel> — vet the pair without touching disk.
# Empty arguments fall back to the defaults. Prints an actionable message on
# >&2 and returns non-zero for an unknown board or kernel line.
kernel_image_validate() {
    local board="${1:-$KERNEL_IMG_DEFAULT_BOARD}"
    local kernel="${2:-$KERNEL_IMG_DEFAULT_KERNEL}"
    if ! _kernel_img_in_list "$board" "$KERNEL_IMG_KNOWN_BOARDS"; then
        echo "Error: unknown BOARD '$board' (known: ${KERNEL_IMG_KNOWN_BOARDS})." >&2
        return 1
    fi
    if ! _kernel_img_in_list "$kernel" "$KERNEL_IMG_KNOWN_KERNELS"; then
        echo "Error: unknown KERNEL '$kernel' (known: ${KERNEL_IMG_KNOWN_KERNELS})." >&2
        return 1
    fi
    return 0
}

# resolve_kernel_image <board> <kernel> — echo the absolute image path for the
# pair, validating the values and that the file exists. Empty arguments fall
# back to lidl / 6.18. On failure, nothing is echoed and a message explaining
# how to build the missing image goes to >&2.
resolve_kernel_image() {
    local board="${1:-$KERNEL_IMG_DEFAULT_BOARD}"
    local kernel="${2:-$KERNEL_IMG_DEFAULT_KERNEL}"

    kernel_image_validate "$board" "$kernel" || return 1

    local img="${KERNEL_IMG_ROOT}/${board}/kernel-${kernel}.img"
    if [ ! -f "$img" ]; then
        echo "Error: kernel image not found: ${img}" >&2
        echo "  Build it: (cd 3-Main-SoC-Realtek-RTL8196E/32-Kernel && BOARD=${board} KERNEL=${kernel} ./build_kernel.sh)" >&2
        return 1
    fi
    printf '%s\n' "$img"
}
