#!/bin/bash
# flash_bootloader.sh — Upload bootloader via TFTP to device in recovery mode
#
# The device must be in download mode (<RealTek> prompt) before running.
#
# Usage: ./flash_bootloader.sh [IP] [IMAGE]
#   IP    - Target IP (default: 192.168.1.6)
#   IMAGE - Image file (default: boot.bin)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

TARGET_IP="${1:-192.168.1.6}"
IMAGE="${2:-${SCRIPT_DIR}/boot.bin}"

if [ ! -f "$IMAGE" ]; then
    echo "Error: $IMAGE not found"
    echo "Run ./build_bootloader.sh first"
    exit 1
fi

SIZE=$(stat -c%s "$IMAGE" 2>/dev/null || stat -f%z "$IMAGE")
NAME=$(basename "$IMAGE")

echo "Flashing ${NAME} (${SIZE} bytes) to ${TARGET_IP}..."
echo ""
echo "  Image:  ${IMAGE}"
echo "  Target: ${TARGET_IP}"
echo ""
read -r -p "Proceed? [y/N] " confirm
if [[ ! "$confirm" =~ ^[yY]$ ]]; then
    echo "Aborted."
    exit 0
fi

tftp -m binary "$TARGET_IP" -c put "$IMAGE"
echo ""
echo "Done. Reboot with: J BFC00000"
