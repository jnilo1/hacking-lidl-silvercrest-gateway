#!/bin/bash
# flash_rtl8196e_lidl.sh — Flash all RTL8196E partitions via TFTP
#
# For gateways still running the ORIGINAL Lidl/Tuya bootloader.
#
# Flash order: rootfs → userdata → kernel → bootloader (single reboot at end).
# The kernel is re-wrapped with an "r6cr" header (reboot=0) so the original
# bootloader does not reboot after flashing it.  The bootloader is flashed
# last and triggers the only reboot.
#
# Usage: ./flash_rtl8196e_lidl.sh [--ip ADDRESS]
#   --ip ADDR  Gateway IP address (default: 192.168.1.6)
#
# J. Nilo - March 2026

set -e

# Check that tftp-hpa client is installed (the script uses its "-c put" syntax)
if ! command -v tftp >/dev/null 2>&1 || ! tftp --version 2>&1 | grep -q '\-c'; then
    echo "Error: tftp-hpa client not found (need the -c flag)." >&2
    echo "Install it with: sudo apt install tftp-hpa" >&2
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 is required to re-wrap the kernel image." >&2
    exit 1
fi

echo "WARNING: This script requires a serial console connection to the gateway."
echo "You must be able to see 'Flash Write Succeeded!' messages on the console."
echo "If you don't have a serial console connected, press Ctrl+C now."
echo ""
read -r -p "Serial console is connected and ready? [y/N] " serial_ok
if [[ ! "$serial_ok" =~ ^[yY]$ ]]; then echo "Aborted."; exit 0; fi
echo ""

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RTL_DIR="${SCRIPT_DIR}/3-Main-SoC-Realtek-RTL8196E"
TARGET_IP="192.168.1.6"

while [ $# -gt 0 ]; do
    case "$1" in
        --ip) shift; TARGET_IP="$1" ;;
        --help|-h)
            echo "Usage: $0 [--ip ADDRESS]"
            echo "Flashes rootfs, userdata, kernel and bootloader in order."
            echo "For gateways with the original Lidl/Tuya bootloader."
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
KERNEL_R6CR=""
cleanup() {
    rm -f "$ETH0_CONF"
    [ -n "$KERNEL_R6CR" ] && rm -f "$KERNEL_R6CR"
}
trap cleanup EXIT

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

# Optional full flash backup via FLR (before any write)
echo ""
read -r -p "Back up the current flash before flashing? [y/N] " do_backup
if [[ "$do_backup" =~ ^[yY]$ ]]; then
    BACKUP_FILE="$(date '+%y%m%d-%H.%M')-Gw-Backup.bin"
    echo ""
    echo "On the bootloader serial console, run:"
    echo "  FLR 80500000 00000000 01000000"
    echo "Then confirm with Y and wait for 'Flash Read Succeeded!'"
    read -r -p "Press Enter when done..."
    echo "Downloading backup to ${BACKUP_FILE}..."
    out=$(timeout 120 tftp -m binary "$TARGET_IP" -c get "$BACKUP_FILE" 2>&1) || true
    if echo "$out" | grep -qiE \
            "error|timeout|timed out|refused|failed|unknown host|illegal"; then
        echo "Warning: backup download failed: $out" >&2
        read -r -p "Continue with flashing anyway? [y/N] " cont
        if [[ ! "$cont" =~ ^[yY]$ ]]; then echo "Aborted."; exit 0; fi
    else
        size=$(stat -c %s "$BACKUP_FILE" 2>/dev/null || echo 0)
        if [ "$size" -eq 16777216 ]; then
            echo "Backup saved: ${BACKUP_FILE} [OK]"
        else
            echo "Warning: ${BACKUP_FILE} is ${size} bytes (expected 16777216)" >&2
            read -r -p "Continue with flashing anyway? [y/N] " cont
            if [[ ! "$cont" =~ ^[yY]$ ]]; then echo "Aborted."; exit 0; fi
        fi
    fi
fi

# --- Re-wrap kernel with r6cr header (reboot=0) ----------------------------
#
# The original bootloader reboots after cs6c (kernel) and boot signatures.
# Wrapping the kernel in r6cr avoids the reboot so we can flash everything
# before the final bootloader flash triggers the only reboot.
#
# The r6cr payload is the entire kernel.img (cs6c header + data + checksum).
# A 2-byte correction is appended so the 16-bit checksum of the payload is 0.

KERNEL_R6CR="$(mktemp "${RTL_DIR}/32-Kernel/kernel_r6cr.XXXXXX")"

python3 -c "
import struct, sys
kernel = open(sys.argv[1], 'rb').read()
burn_addr = struct.unpack('>I', kernel[8:12])[0]   # burnAddr from cs6c header
s = 0
for i in range(0, len(kernel) - 1, 2):
    s += (kernel[i] << 8) | kernel[i + 1]
s &= 0xFFFF
payload = kernel + struct.pack('>H', (-s) & 0xFFFF)
hdr = struct.pack('>4sIII', b'r6cr', 0x80C00000, burn_addr, len(payload))
open(sys.argv[2], 'wb').write(hdr + payload)
" "$KERNEL_IMG" "$KERNEL_R6CR"

KERNEL_R6CR_NAME="$(basename "$KERNEL_R6CR")"

# Summary
echo ""
echo "Ready to flash 4 partitions to ${TARGET_IP}."
echo "Order: rootfs → userdata → kernel → bootloader (reboot)"
echo ""
echo "After each upload, wait for 'Flash Write Succeeded!' on the serial"
echo "console before confirming."
echo ""
read -r -p "Proceed? [y/N] " confirm
if [[ ! "$confirm" =~ ^[yY]$ ]]; then echo "Aborted."; exit 0; fi

# Helper: flash one image and wait for serial confirmation
# Args: label dir file timeout_seconds
flash_image() {
    local label="$1" dir="$2" file="$3" tmo="$4"
    echo ""
    echo "Flashing ${label}..."
    cd "$dir"
    out=$(timeout "$tmo" tftp -m binary "$TARGET_IP" -c put "$file" 2>&1) || true
    cd "$SCRIPT_DIR"
    if echo "$out" | grep -qiE \
        "error|timeout|timed out|refused|failed|unknown host|access denied|disk full|illegal|not connected|unknown transfer"; then
        echo "Error: transfer failed: $out" >&2
        exit 1
    fi
    echo "${label} uploaded."
    read -r -p "Flash Write Succeeded on serial console? [y/N] " r
    if [[ ! "$r" =~ ^[yY]$ ]]; then echo "Aborted."; exit 1; fi
}

flash_image "rootfs"     "${RTL_DIR}/33-Rootfs"     "rootfs.bin"         30
echo "Note: userdata is 12 MB — transfer and flash may take 1-2 minutes."
flash_image "userdata"   "${RTL_DIR}/34-Userdata"   "userdata.bin"       120
flash_image "kernel"     "${RTL_DIR}/32-Kernel"     "$KERNEL_R6CR_NAME"  30

echo ""
echo "Flashing bootloader (gateway will reboot after this)..."
cd "${RTL_DIR}/31-Bootloader"
out=$(timeout 15 tftp -m binary "$TARGET_IP" -c put boot.bin 2>&1) || true
cd "$SCRIPT_DIR"
if echo "$out" | grep -qiE \
    "error|timeout|timed out|refused|failed|unknown host|access denied|disk full|illegal|not connected|unknown transfer"; then
    echo "Error: transfer failed: $out" >&2
    exit 1
fi
echo ""
echo "Done. Gateway will reboot with the new firmware."
