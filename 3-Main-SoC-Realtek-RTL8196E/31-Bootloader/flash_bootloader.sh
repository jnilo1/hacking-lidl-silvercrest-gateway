#!/bin/bash
# flash_bootloader.sh — Upload bootloader via TFTP to device in recovery mode
#
# The device must be in download mode (<RealTek> prompt) before running.
#
# Usage: ./flash_bootloader.sh [IP] [IMAGE]
#   IP    - Target IP (default: 192.168.1.6)
#   IMAGE - Image file (default: boot.bin)
#
# Environment variables (optional overrides):
#   CONFIRM        - Set to "y" to skip the "Proceed?" prompt
#   TRIES          - ARP probe attempts (default: 10)
#   PORT           - UDP port used to trigger ARP (default: 69)
#   SLEEP_BETWEEN  - Pause between ARP probes in seconds (default: 0.2)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Check prerequisites
tftp_usage="$(tftp --help 2>&1 || true)"
if ! command -v tftp >/dev/null 2>&1 || ! echo "$tftp_usage" | grep -q '\-c'; then
    echo "Error: tftp-hpa client not found (need the -c flag)." >&2
    echo "Install it with: sudo apt install tftp-hpa" >&2
    exit 1
fi
if ! command -v nc >/dev/null 2>&1; then
    echo "Error: netcat (nc) not found." >&2
    echo "Install it with: sudo apt install netcat-openbsd" >&2
    exit 1
fi

TARGET_IP="${1:-192.168.1.6}"
IMAGE="${2:-${SCRIPT_DIR}/boot.bin}"

TRIES="${TRIES:-10}"
PORT="${PORT:-69}"
SLEEP_BETWEEN="${SLEEP_BETWEEN:-0.2}"

if [ ! -f "$IMAGE" ]; then
    echo "Error: $IMAGE not found"
    echo "Run ./build_bootloader.sh first"
    exit 1
fi

SIZE=$(stat -c%s "$IMAGE" 2>/dev/null || stat -f%z "$IMAGE")
NAME=$(basename "$IMAGE")

# --- helpers ---------------------------------------------------------------

get_iface_for_ip() {
    local ip="$1"
    ip route get "$ip" 2>/dev/null \
        | awk '/ dev /{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'
}

neigh_has_lladdr() {
    local line="$1"
    echo "$line" | grep -Eqi 'lladdr [0-9a-f]{2}(:[0-9a-f]{2}){5}'
}

trigger_kernel_arp_via_udp() {
    local ip="$1"
    local port="${2:-69}"
    (
        echo -n X >"/dev/udp/$ip/$port" 2>/dev/null || true
    ) &
    local pid=$!
    sleep 0.3
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

check_bootloader_reachable() {
    local ip="$1"
    local iface="$2"

    # Flush any stale ARP entry to force a fresh resolution
    ip neigh del "$ip" dev "$iface" 2>/dev/null || true

    for _ in $(seq 1 "$TRIES"); do
        trigger_kernel_arp_via_udp "$ip" "$PORT"

        local nei
        nei="$(ip neigh show "$ip" dev "$iface" 2>/dev/null || true)"

        if [ -n "$nei" ] && neigh_has_lladdr "$nei"; then
            return 0
        fi

        sleep "$SLEEP_BETWEEN"
    done
    return 1
}

# --- main ------------------------------------------------------------------

echo "Checking if gateway is in boot mode..."

IFACE="$(get_iface_for_ip "$TARGET_IP")"
if [ -z "$IFACE" ]; then
    echo "Error: cannot determine outgoing interface to ${TARGET_IP} (ip route get failed)." >&2
    exit 1
fi

# Reject if routed — ARP would resolve the gateway, not the target
if ip route get "$TARGET_IP" 2>/dev/null | grep -qE '\svia\s'; then
    echo "Error: ${TARGET_IP} is reached via a gateway (routed). Must be on the same L2 segment." >&2
    exit 1
fi

if ! check_bootloader_reachable "$TARGET_IP" "$IFACE"; then
    echo "Error: ${TARGET_IP} unreachable — check cable and that device is in download mode." >&2
    exit 1
fi

echo "Flashing ${NAME} (${SIZE} bytes) to ${TARGET_IP}..."
echo ""
if [ "${CONFIRM:-}" != "y" ]; then
    read -r -p "Proceed? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        echo "Aborted."
        exit 0
    fi
fi

NOTIFY_PORT=9999
NOTIFY_TMO=30

notify_file=$(mktemp)
(timeout "$NOTIFY_TMO" nc -u -l -p "$NOTIFY_PORT" > "$notify_file" 2>/dev/null) &
nc_pid=$!
sleep 0.2

echo "Uploading..."
cd "$SCRIPT_DIR"
out=$(timeout 15 tftp -m binary "$TARGET_IP" -c put "$NAME" 2>&1) || true
if echo "$out" | grep -qiE \
    "error|timeout|timed out|refused|failed|unknown host|access denied|disk full|illegal|not connected|unknown transfer"; then
    kill "$nc_pid" 2>/dev/null; wait "$nc_pid" 2>/dev/null; rm -f "$notify_file"
    echo "Error: transfer failed: $out" >&2
    exit 1
fi
echo "Uploaded. Waiting for flash write..."
while kill -0 "$nc_pid" 2>/dev/null; do
    [ -s "$notify_file" ] && { kill "$nc_pid" 2>/dev/null; break; }
    sleep 0.5
done
wait "$nc_pid" 2>/dev/null || true
result=$(tr -d '\0' < "$notify_file")
rm -f "$notify_file"

if [ "$result" = "OK" ]; then
    echo "Flash Write Succeeded."
elif [ "$result" = "FAIL" ]; then
    echo "Error: flash write FAILED on gateway." >&2
    exit 1
else
    echo "Warning: no notification received (timeout ${NOTIFY_TMO}s)." >&2
    echo "Check the serial console for status."
fi
echo ""
echo "Done."
echo "Reboot: J BFC00000  (serial console)  or  hard reset the device"
