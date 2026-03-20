#!/bin/bash
# flash_userdata.sh — Configure network, rebuild and flash userdata partition
#
# Asks for network configuration (static IP or DHCP), rebuilds userdata.bin,
# then uploads it to the device in download mode via TFTP.
#
# Usage: ./flash_userdata.sh [IP]
#   IP - Target IP (default: 192.168.1.6)
#
# Environment variables (optional, for non-interactive use):
#   NET_MODE       - "static" or "dhcp" (skip network prompt)
#   IPADDR         - Static IP address (default: 192.168.1.88)
#   NETMASK        - Netmask (default: 255.255.255.0)
#   GATEWAY        - Default gateway (default: 192.168.1.1)
#   RADIO_MODE     - "zigbee" or "thread" (skip radio prompt)
#   CONFIRM        - Set to "y" to skip the "Proceed?" prompt
#   TRIES          - ARP probe attempts (default: 10)
#   PORT           - UDP port used to trigger ARP (default: 69)
#   SLEEP_BETWEEN  - Pause between ARP probes in seconds (default: 0.2)
#
# J. Nilo - December 2025

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_IP="${1:-192.168.1.6}"

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

TRIES="${TRIES:-10}"
PORT="${PORT:-69}"
SLEEP_BETWEEN="${SLEEP_BETWEEN:-0.2}"

ETH0_CONF="${SCRIPT_DIR}/skeleton/etc/eth0.conf"
RADIO_CONF="${SCRIPT_DIR}/skeleton/etc/radio.conf"
# Save skeleton + userdata.bin before config injection, restore on exit
SKEL_BACKUP=$(mktemp -d)
cp -a "${SCRIPT_DIR}/skeleton/etc" "$SKEL_BACKUP/etc"
cp -a "${SCRIPT_DIR}/skeleton/ssh" "$SKEL_BACKUP/ssh" 2>/dev/null || true
cp "${SCRIPT_DIR}/userdata.bin" "$SKEL_BACKUP/userdata.bin" 2>/dev/null || true
cleanup() {
    rm -rf "${SCRIPT_DIR}/skeleton/etc" "${SCRIPT_DIR}/skeleton/ssh"
    cp -a "$SKEL_BACKUP/etc" "${SCRIPT_DIR}/skeleton/etc"
    [ -d "$SKEL_BACKUP/ssh" ] && cp -a "$SKEL_BACKUP/ssh" "${SCRIPT_DIR}/skeleton/ssh"
    [ -f "$SKEL_BACKUP/userdata.bin" ] && cp "$SKEL_BACKUP/userdata.bin" "${SCRIPT_DIR}/userdata.bin"
    rm -rf "$SKEL_BACKUP"
}
trap cleanup EXIT

# --- Network configuration -------------------------------------------------

# "skip" = config already in skeleton (preserved from gateway by flash_remote.sh)
if [ "${NET_MODE:-}" = "skip" ]; then
    echo "→ Network config preserved from gateway"
else
    if [ -n "${NET_MODE:-}" ]; then
        net_choice="$NET_MODE"
    else
        echo "Network configuration for the gateway:"
        echo "  [1] Static IP (recommended)"
        echo "  [2] DHCP"
        read -r -p "Choice [1]: " net_choice
        net_choice="${net_choice:-1}"
    fi

    if [ "$net_choice" = "static" ] || [ "$net_choice" = "1" ]; then
        if [ -z "${NET_MODE:-}" ]; then
            read -r -p "IP address [192.168.1.88]: " IPADDR
            read -r -p "Netmask    [255.255.255.0]: " NETMASK
            read -r -p "Gateway    [192.168.1.1]:   " GATEWAY
        fi
        IPADDR="${IPADDR:-192.168.1.88}"
        NETMASK="${NETMASK:-255.255.255.0}"
        GATEWAY="${GATEWAY:-192.168.1.1}"
        printf 'IPADDR=%s\nNETMASK=%s\nGATEWAY=%s\n' "$IPADDR" "$NETMASK" "$GATEWAY" > "$ETH0_CONF"
        # Optional DNS/domain (defaults: gateway IP, no search domain)
        if [ -z "${NET_MODE:-}" ]; then
            read -r -p "DNS server [$GATEWAY]: " DNS
            read -r -p "Search domain []: " DOMAIN
        fi
        [ -n "${DNS:-}" ] && echo "DNS=$DNS" >> "$ETH0_CONF"
        [ -n "${DOMAIN:-}" ] && echo "DOMAIN=$DOMAIN" >> "$ETH0_CONF"
        echo "→ Static IP: $IPADDR / $NETMASK via $GATEWAY"

        # Update gateway IP in Docker Compose and Z2M config files
        DOCKER_DIR="${SCRIPT_DIR}/../../2-Zigbee-Radio-Silabs-EFR32/26-OT-RCP/docker"
        if [ -d "$DOCKER_DIR" ]; then
            sed -i "s|RCP_HOST=[0-9.]*|RCP_HOST=${IPADDR}|" \
                "$DOCKER_DIR/docker-compose-otbr-host.yml" 2>/dev/null || true
            sed -i "s|tcp://[0-9.]*:8888|tcp://${IPADDR}:8888|" \
                "$DOCKER_DIR/z2m/configuration.yaml" 2>/dev/null || true
        fi
    else
        rm -f "$ETH0_CONF"
        echo "→ DHCP"
    fi
fi
echo ""

# --- Radio mode configuration ----------------------------------------------

if [ "${RADIO_MODE:-}" = "skip" ]; then
    echo "→ Radio config preserved from gateway"
elif [ -n "${RADIO_MODE:-}" ]; then
    radio_choice="$RADIO_MODE"
else
    echo "Radio mode (EFR32 firmware must match):"
    echo "  [1] Zigbee — serialgateway on port 8888 (NCP or RCP+zigbeed)"
    echo "  [2] Thread — OTBR border router, REST API on port 8081 (OT-RCP)"
    read -r -p "Choice [1]: " radio_choice
    radio_choice="${radio_choice:-1}"
fi

if [ "${RADIO_MODE:-}" != "skip" ]; then
    if [ "${radio_choice:-}" = "thread" ] || [ "${radio_choice:-}" = "2" ]; then
        echo "MODE=otbr" > "$RADIO_CONF"
        echo "→ Thread Border Router (otbr-agent)"
    else
        rm -f "$RADIO_CONF"
        echo "→ Zigbee (serialgateway)"
    fi
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
if [ "${CONFIRM:-}" != "y" ]; then
    read -r -p "Proceed? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        echo "Aborted."
        exit 0
    fi
fi

NOTIFY_PORT=9999
NOTIFY_TMO=180

notify_file=$(mktemp)
(timeout "$NOTIFY_TMO" nc -u -l -p "$NOTIFY_PORT" > "$notify_file" 2>/dev/null) &
nc_pid=$!
sleep 0.2

echo "Note: userdata is 12 MB — transfer and flash may take 1-2 minutes."
echo "Uploading..."
cd "$SCRIPT_DIR"
out=$(timeout 120 tftp -m binary "$TARGET_IP" -c put userdata.bin 2>&1) || true
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
