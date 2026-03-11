#!/bin/bash
# split_flash.sh — Split a full 16 MB flash backup into individual partitions
#
# Usage: ./split_flash.sh <flash_full.bin> [layout]
#   flash_full.bin - Full flash image (must be exactly 16 MiB)
#   layout         - "custom" (4 partitions, default) or "lidl" (5 partitions)
#
# Output files are created next to the input file:
#   mtd0_boot+cfg.bin, mtd1_kernel.bin, mtd2_rootfs.bin, ...
#
# J. Nilo - March 2026

set -euo pipefail

IMAGE="${1:-}"
LAYOUT="${2:-custom}"

if [ -z "$IMAGE" ] || [ ! -f "$IMAGE" ]; then
    echo "Usage: $0 <flash_full.bin> [custom|lidl]"
    echo "  custom  4 partitions (default)"
    echo "  lidl    5 partitions (original Lidl/Tuya)"
    exit 1
fi

SIZE=$(stat -c%s "$IMAGE" 2>/dev/null || stat -f%z "$IMAGE")
EXPECTED=$((16 * 1024 * 1024))

if [ "$SIZE" -ne "$EXPECTED" ]; then
    echo "Error: expected 16 MiB (${EXPECTED} bytes), got ${SIZE} bytes." >&2
    exit 1
fi

OUT_DIR="$(dirname "$IMAGE")"

# Partition definitions: name offset_hex size_hex
case "$LAYOUT" in
    custom)
        PARTS=(
            "mtd0_boot+cfg    00000000 00020000"
            "mtd1_kernel      00020000 001E0000"
            "mtd2_rootfs      00200000 00200000"
            "mtd3_userdata    00400000 00C00000"
        )
        ;;
    lidl)
        PARTS=(
            "mtd0_boot+cfg    00000000 00020000"
            "mtd1_kernel      00020000 001E0000"
            "mtd2_rootfs      00200000 00200000"
            "mtd3_tuya-label  00400000 00020000"
            "mtd4_jffs2-fs    00420000 00BE0000"
        )
        ;;
    *)
        echo "Error: unknown layout '$LAYOUT' (use 'custom' or 'lidl')." >&2
        exit 1
        ;;
esac

echo "Splitting $(basename "$IMAGE") (${LAYOUT} layout, ${#PARTS[@]} partitions):"
echo ""

for part in "${PARTS[@]}"; do
    read -r name offset_hex size_hex <<< "$part"
    offset=$((16#${offset_hex}))
    size=$((16#${size_hex}))
    outfile="${OUT_DIR}/${name}.bin"

    dd if="$IMAGE" of="$outfile" bs=1 skip="$offset" count="$size" status=none
    printf "  %-20s  %7d bytes  (0x%s + 0x%s)\n" "${name}.bin" "$size" "$offset_hex" "$size_hex"
done

echo ""
echo "Done. Files saved to ${OUT_DIR}/"
