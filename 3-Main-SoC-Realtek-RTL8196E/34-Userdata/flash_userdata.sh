#!/bin/bash
# flash_userdata.sh — Configure network, rebuild and flash userdata partition
#
# Asks for network configuration (static IP or DHCP), rebuilds userdata.bin,
# then uploads it to the device in download mode via TFTP.
#
# Usage: ./flash_userdata.sh [IP]
#   IP - Target IP (default: 192.168.1.6)
#
# Environment variables (optional overrides):
#   TRIES          - ARP probe attempts (default: 10)
#   PORT           - UDP port used to trigger ARP (default: 69)
#   SLEEP_BETWEEN  - Pause between ARP probes in seconds (default: 0.2)
#
# J. Nilo - December 2025

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_IP="${1:-192.168.1.6}"

TRIES="${TRIES:-10}"
PORT="${PORT:-69}"
SLEEP_BETWEEN="${SLEEP_BETWEEN:-0.2}"

ETH0_CONF="${SCRIPT_DIR}/skeleton/etc/eth0.conf"

# Remove eth0.conf on exit (success or failure) to keep skeleton clean
cleanup() { rm -f "$ETH0_CONF"; }
trap cleanup EXIT

# --- Network configuration -------------------------------------------------

echo "Network configuration for the gateway:"
echo "  [1] Static IP (recommended)"
echo "  [2] DHCP"
read -r -p "Choice [1]: " net_choice
net_choice="${net_choice:-1}"

if [ "$net_choice" = "1" ]; then
    read -r -p "IP address [192.168.1.88]: " IPADDR
    read -r -p "Netmask    [255.255.255.0]: " NETMASK
    read -r -p "Gateway    [192.168.1.1]:   " GATEWAY
    IPADDR="${IPADDR:-192.168.1.88}"
    NETMASK="${NETMASK:-255.255.255.0}"
    GATEWAY="${GATEWAY:-192.168.1.1}"
    printf 'IPADDR=%s\nNETMASK=%s\nGATEWAY=%s\n' "$IPADDR" "$NETMASK" "$GATEWAY" > "$ETH0_CONF"
    echo "→ Static IP: $IPADDR / $NETMASK via $GATEWAY"
else
    rm -f "$ETH0_CONF"
    echo "→ DHCP"
fi
echo ""

# --- Rebuild ---------------------------------------------------------------

echo "Rebuilding userdata..."
"${SCRIPT_DIR}/build_userdata.sh" --jffs2-only
echo ""

# --- helpers ---------------------------------------------------------------

get_iface_for_ip() {
    local ip="$1"
    ip route get "$ip" 2>/dev/null \
        | awk '/ dev /{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'
}

neigh_has_lladdr() {
    echo "$1" | grep -Eqi 'lladdr [0-9a-f]{2}(:[0-9a-f]{2}){5}'
}

trigger_kernel_arp_via_udp() {
    local ip="$1" port="${2:-69}"
    ( echo -n X >"/dev/udp/$ip/$port" 2>/dev/null || true ) &
    local pid=$!
    sleep 0.3
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

check_bootloader_reachable() {
    local ip="$1" iface="$2"
    ip neigh del "$ip" dev "$iface" 2>/dev/null || true
    for _ in $(seq 1 "$TRIES"); do
        trigger_kernel_arp_via_udp "$ip" "$PORT"
        local nei
        nei="$(ip neigh show "$ip" dev "$iface" 2>/dev/null || true)"
        if [ -n "$nei" ] && neigh_has_lladdr "$nei"; then return 0; fi
        sleep "$SLEEP_BETWEEN"
    done
    return 1
}

# --- Flash -----------------------------------------------------------------

IMAGE="${SCRIPT_DIR}/userdata.bin"
SIZE=$(stat -c%s "$IMAGE" 2>/dev/null || stat -f%z "$IMAGE")

echo "Checking if gateway is in boot mode..."

IFACE="$(get_iface_for_ip "$TARGET_IP")"
if [ -z "$IFACE" ]; then
    echo "Error: cannot determine outgoing interface to ${TARGET_IP}." >&2
    exit 1
fi

if ip route get "$TARGET_IP" 2>/dev/null | grep -qE '\svia\s'; then
    echo "Error: ${TARGET_IP} is reached via a gateway (routed). Must be on the same L2 segment." >&2
    exit 1
fi

if ! check_bootloader_reachable "$TARGET_IP" "$IFACE"; then
    echo "Error: ${TARGET_IP} unreachable — check cable and that device is in download mode." >&2
    exit 1
fi

echo "Flashing userdata.bin (${SIZE} bytes) to ${TARGET_IP}..."
echo ""
read -r -p "Proceed? [y/N] " confirm
if [[ ! "$confirm" =~ ^[yY]$ ]]; then
    echo "Aborted."
    exit 0
fi

echo "Note: userdata is 12 MB — transfer and flash may take 1-2 minutes."
echo "Uploading..."
cd "$SCRIPT_DIR"
out=$(timeout 120 tftp -m binary "$TARGET_IP" -c put userdata.bin 2>&1) || true
if echo "$out" | grep -qiE \
    "error|timeout|timed out|refused|failed|unknown host|access denied|disk full|illegal|not connected|unknown transfer"; then
    echo "Error: transfer failed: $out" >&2
    exit 1
fi
echo ""
echo "Done."
echo "Reboot: J BFC00000  (serial console)  or  hard reset the device"
