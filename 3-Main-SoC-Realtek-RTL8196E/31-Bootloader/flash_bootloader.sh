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

echo "Checking if gateway is in boot mode..."

# Determine the local outgoing interface toward the target
IFACE="$(ip route get "$TARGET_IP" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
if [ -z "${IFACE:-}" ]; then
    echo "Error: cannot determine outgoing interface to ${TARGET_IP} (ip route get failed)." >&2
    exit 1
fi

# Reject if routed — ARP would resolve the gateway, not the target
if ip route get "$TARGET_IP" 2>/dev/null | grep -qE '\svia\s'; then
    echo "Error: ${TARGET_IP} is reached via a gateway (routed). Must be same L2 segment." >&2
    exit 1
fi

TRIES="${TRIES:-10}"
PORT="${PORT:-69}"
SLEEP_BETWEEN="${SLEEP_BETWEEN:-0.2}"

ok=0
for _ in $(seq 1 "$TRIES"); do
    # Trigger kernel ARP resolution via a UDP send (no root required)
    bash -c 'echo -n X > /dev/udp/'"$TARGET_IP"'/'"$PORT"'' >/dev/null 2>&1 || true
    sleep 0.2

    LINE="$(ip neigh show "$TARGET_IP" dev "$IFACE" 2>/dev/null || true)"

    # Bootloader detected only if a MAC address was resolved (lladdr)
    if echo "$LINE" | grep -qiE 'lladdr [0-9a-f]{2}(:[0-9a-f]{2}){5}'; then
        ok=1
        break
    fi

    sleep "$SLEEP_BETWEEN"
done

if [ "$ok" -ne 1 ]; then
    echo "Error: ${TARGET_IP} unreachable — check cable and that device is in download mode." >&2
    exit 1
fi

echo "Flashing ${NAME} (${SIZE} bytes) to ${TARGET_IP}..."
echo ""
read -r -p "Proceed? [y/N] " confirm
if [[ ! "$confirm" =~ ^[yY]$ ]]; then
    echo "Aborted."
    exit 0
fi

cd "$SCRIPT_DIR"
out=$(timeout 15 tftp -m binary "$TARGET_IP" -c put "$NAME" 2>&1) || true
if echo "$out" | grep -qiE \
    "error|timeout|timed out|refused|failed|unknown host|access denied|disk full|illegal|not connected|unknown transfer"; then
    echo "Error: transfer failed: $out" >&2
    exit 1
fi
echo ""
echo "Done."
echo "Reboot: J BFC00000  (serial console)  or  hard reset the device"
