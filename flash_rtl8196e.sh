#!/bin/bash
# flash_rtl8196e.sh — Flash all RTL8196E partitions via TFTP
#
# Flashes the complete firmware in order: bootloader, rootfs, userdata, kernel.
# The device must be in download mode (<RealTek> prompt) before running.
#
# To flash individual partitions, use the scripts in each subdirectory:
#   3-Main-SoC-Realtek-RTL8196E/31-Bootloader/flash_bootloader.sh
#   3-Main-SoC-Realtek-RTL8196E/32-Kernel/flash_kernel.sh
#   3-Main-SoC-Realtek-RTL8196E/33-Rootfs/flash_rootfs.sh
#   3-Main-SoC-Realtek-RTL8196E/34-Userdata/flash_userdata.sh
#
# Usage: ./flash_rtl8196e.sh [--ip ADDRESS]
#   --ip ADDR  Gateway IP address (default: 192.168.1.6)
#
# J. Nilo - December 2025

set -e

# Check that tftp-hpa client is installed (the script uses its "-c put" syntax)
if ! command -v tftp >/dev/null 2>&1 || ! tftp --version 2>&1 | grep -q '\-c'; then
    echo "Error: tftp-hpa client not found (need the -c flag)." >&2
    echo "Install it with: sudo apt install tftp-hpa" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RTL_DIR="${SCRIPT_DIR}/3-Main-SoC-Realtek-RTL8196E"
TARGET_IP="192.168.1.6"

while [ $# -gt 0 ]; do
    case "$1" in
        --ip) shift; TARGET_IP="$1" ;;
        --help|-h)
            echo "Usage: $0 [--ip ADDRESS]"
            echo "Flashes bootloader, rootfs, userdata and kernel in order."
            exit 0
            ;;
        *) echo "Unknown option: $1. Use --help for usage."; exit 1 ;;
    esac
    shift
done

# Image locations
BOOTLOADER_IMG="${RTL_DIR}/31-Bootloader/boot.bin"
ROOTFS_IMG="${RTL_DIR}/33-Rootfs/rootfs.bin"
USERDATA_DIR="${RTL_DIR}/34-Userdata"
USERDATA_IMG="${USERDATA_DIR}/userdata.bin"
KERNEL_IMG="${RTL_DIR}/32-Kernel/kernel.img"

# Check all images exist
MISSING=0
for f in "$BOOTLOADER_IMG" "$ROOTFS_IMG" "$USERDATA_IMG" "$KERNEL_IMG"; do
    [ ! -f "$f" ] && echo "Error: $(basename "$f") not found" && MISSING=1
done
if [ $MISSING -eq 1 ]; then
    echo "Run ./build_rtl8196e.sh first"
    exit 1
fi

# --- Network configuration -------------------------------------------------

ETH0_CONF="${USERDATA_DIR}/skeleton/etc/eth0.conf"

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
# --- Radio mode ---------------------------------------------------------------

RADIO_CONF="${USERDATA_DIR}/skeleton/etc/radio.conf"
cleanup() { rm -f "$ETH0_CONF" "$RADIO_CONF"; }
trap cleanup EXIT

echo "Radio mode (EFR32 firmware must match):"
echo "  [1] Zigbee — serialgateway on port 8888 (NCP or RCP+zigbeed)"
echo "  [2] Thread — OTBR border router, REST API on port 8081 (OT-RCP)"
read -r -p "Choice [1]: " radio_choice
radio_choice="${radio_choice:-1}"

if [ "$radio_choice" = "2" ]; then
    echo "MODE=otbr" > "$RADIO_CONF"
    echo "→ Thread (OTBR)"
else
    rm -f "$RADIO_CONF"
    echo "→ Zigbee"
fi
echo ""

echo "Rebuilding userdata..."
"${USERDATA_DIR}/build_userdata.sh" --jffs2-only
echo ""

# --- ARP-based boot mode detection (no root required) ----------------------
echo "Checking if gateway is in boot mode..."

IFACE="$(ip route get "$TARGET_IP" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
if [ -z "${IFACE:-}" ]; then
    echo "Error: cannot determine outgoing interface to ${TARGET_IP}." >&2
    exit 1
fi
if ip route get "$TARGET_IP" 2>/dev/null | grep -qE '\svia\s'; then
    echo "Error: ${TARGET_IP} is reached via a gateway (routed). Must be same L2 segment." >&2
    exit 1
fi

TRIES="${TRIES:-10}" PORT="${PORT:-69}" SLEEP_BETWEEN="${SLEEP_BETWEEN:-0.2}"
ok=0
for _ in $(seq 1 "$TRIES"); do
    bash -c 'echo -n X > /dev/udp/'"$TARGET_IP"'/'"$PORT"'' >/dev/null 2>&1 || true
    sleep 0.2
    LINE="$(ip neigh show "$TARGET_IP" dev "$IFACE" 2>/dev/null || true)"
    if echo "$LINE" | grep -qiE 'lladdr [0-9a-f]{2}(:[0-9a-f]{2}){5}'; then
        ok=1; break
    fi
    sleep "$SLEEP_BETWEEN"
done
if [ "$ok" -ne 1 ]; then
    echo "Error: ${TARGET_IP} not detected — is the device in download mode?" >&2
    exit 1
fi

# Optional full flash backup via TFTP GET (bootloader reads flash automatically)
echo ""
read -r -p "Back up the current flash before flashing? [y/N] " do_backup
if [[ "$do_backup" =~ ^[yY]$ ]]; then
    BACKUP_FILE="$(date '+%y%m%d-%H.%M')-Gw-Backup.bin"
    echo "Downloading full flash backup to ${BACKUP_FILE}..."
    echo "(Bootloader reads 16 MB SPI flash into RAM, then serves via TFTP)"
    out=$(timeout 180 tftp -m binary "$TARGET_IP" -c get backup "$BACKUP_FILE" 2>&1) || true
    if echo "$out" | grep -qiE \
            "error|timeout|timed out|refused|failed|unknown host|illegal"; then
        echo "Warning: backup download failed: $out" >&2
        read -r -p "Continue with flashing anyway? [y/N] " cont
        if [[ ! "$cont" =~ ^[yY]$ ]]; then echo "Aborted."; exit 0; fi
    else
        size=$(stat -c %s "$BACKUP_FILE" 2>/dev/null || echo 0)
        if [ "$size" -eq 16777216 ]; then
            echo "Backup saved: ${BACKUP_FILE} (16 MB) [OK]"
        else
            echo "Warning: ${BACKUP_FILE} is ${size} bytes (expected 16777216)" >&2
            read -r -p "Continue with flashing anyway? [y/N] " cont
            if [[ ! "$cont" =~ ^[yY]$ ]]; then echo "Aborted."; exit 0; fi
        fi
    fi
fi

# Summary
echo ""
echo "Ready to flash 4 partitions to ${TARGET_IP}."
echo ""
read -r -p "Proceed? [y/N] " confirm
if [[ ! "$confirm" =~ ^[yY]$ ]]; then echo "Aborted."; exit 0; fi

NOTIFY_PORT=9999

# Helper: flash one image and wait for bootloader UDP notification
# Args: label dir file tftp_timeout notify_timeout
flash_image() {
    local label="$1" dir="$2" file="$3" tftp_tmo="$4" notify_tmo="$5"
    echo ""
    echo "Flashing ${label}..."

    # Start UDP listener BEFORE tftp (so we don't miss the notification)
    local notify_file
    notify_file=$(mktemp)
    (timeout "$notify_tmo" nc -u -l -p "$NOTIFY_PORT" -w "$notify_tmo" > "$notify_file" 2>/dev/null) &
    local nc_pid=$!
    sleep 0.2  # let nc bind the port

    cd "$dir"
    out=$(timeout "$tftp_tmo" tftp -m binary "$TARGET_IP" -c put "$file" 2>&1) || true
    cd "$SCRIPT_DIR"
    if echo "$out" | grep -qiE \
        "error|timeout|timed out|refused|failed|unknown host|access denied|disk full|illegal|not connected|unknown transfer"; then
        kill "$nc_pid" 2>/dev/null; wait "$nc_pid" 2>/dev/null
        rm -f "$notify_file"
        echo "Error: transfer failed: $out" >&2
        exit 1
    fi
    echo "${label} uploaded. Waiting for flash write..."

    # Wait for bootloader notification
    wait "$nc_pid" 2>/dev/null
    local result
    result=$(tr -d '\0' < "$notify_file")
    rm -f "$notify_file"

    if [ "$result" = "OK" ]; then
        echo "${label}: Flash Write Succeeded."
    elif [ "$result" = "FAIL" ]; then
        echo "Error: ${label} flash write FAILED on gateway." >&2
        exit 1
    else
        echo "Warning: no notification received (timeout after ${notify_tmo}s)." >&2
        echo "Check the serial console for status." >&2
        read -r -p "Continue? [y/N] " r
        if [[ ! "$r" =~ ^[yY]$ ]]; then echo "Aborted."; exit 1; fi
    fi
}

flash_image "bootloader" "${RTL_DIR}/31-Bootloader" "boot.bin"     15  30
flash_image "rootfs"     "${RTL_DIR}/33-Rootfs"     "rootfs.bin"   30  60
flash_image "userdata"   "${RTL_DIR}/34-Userdata"   "userdata.bin" 120 180

echo ""
echo "Flashing kernel (auto-reboots on success)..."
cd "${RTL_DIR}/32-Kernel"
notify_file=$(mktemp)
(timeout 60 nc -u -l -p "$NOTIFY_PORT" -w 60 > "$notify_file" 2>/dev/null) &
nc_pid=$!
sleep 0.2
out=$(timeout 30 tftp -m binary "$TARGET_IP" -c put kernel.img 2>&1) || true
cd "$SCRIPT_DIR"
if echo "$out" | grep -qiE \
    "error|timeout|timed out|refused|failed|unknown host|access denied|disk full|illegal|not connected|unknown transfer"; then
    kill "$nc_pid" 2>/dev/null; wait "$nc_pid" 2>/dev/null
    rm -f "$notify_file"
    echo "Error: transfer failed: $out" >&2
    exit 1
fi
echo "Kernel uploaded. Waiting for flash write..."
wait "$nc_pid" 2>/dev/null
result=$(tr -d '\0' < "$notify_file")
rm -f "$notify_file"

if [ "$result" = "OK" ]; then
    echo "Kernel: Flash Write Succeeded."
elif [ "$result" = "FAIL" ]; then
    echo "Error: kernel flash write FAILED." >&2
    exit 1
else
    echo "Warning: no notification received." >&2
fi
echo ""
echo "Done. Gateway is rebooting with the new firmware."
