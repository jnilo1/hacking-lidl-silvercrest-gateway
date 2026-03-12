#!/bin/bash
# flash_rtl8196e.sh — Flash all RTL8196E partitions via TFTP
#
# Unified flash script that auto-detects the bootloader type (ping probe):
#   - Custom (V1.2/V2): bootloader first, UDP notifications, no serial needed
#   - Tuya (original):  bootloader last, r6cr kernel wrapper, serial console required
#
# The device must be in download mode (<RealTek> prompt) before running.
# A backup via backup_gateway.sh is proposed before flashing.
#
# To flash individual partitions, use the scripts in each subdirectory:
#   3-Main-SoC-Realtek-RTL8196E/31-Bootloader/flash_bootloader.sh
#   3-Main-SoC-Realtek-RTL8196E/32-Kernel/flash_kernel.sh
#   3-Main-SoC-Realtek-RTL8196E/33-Rootfs/flash_rootfs.sh
#   3-Main-SoC-Realtek-RTL8196E/34-Userdata/flash_userdata.sh
#
# Usage: ./flash_rtl8196e.sh [--boot-ip ADDRESS]
#   --boot-ip ADDR  Gateway IP in bootloader mode (default: 192.168.1.6)
#
# J. Nilo - March 2026

set -e

# Check that tftp-hpa client is installed (the script uses its "-c put" syntax)
tftp_usage="$(tftp --help 2>&1 || true)"
if ! command -v tftp >/dev/null 2>&1 || ! echo "$tftp_usage" | grep -q '\-c'; then
    echo "Error: tftp-hpa client not found (need the -c flag)." >&2
    echo "Install it with: sudo apt install tftp-hpa" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RTL_DIR="${SCRIPT_DIR}/3-Main-SoC-Realtek-RTL8196E"
BOOT_IP="192.168.1.6"

# Propose backup before anything else (gateway should still be running Linux)
echo ""
echo "It is recommended to back up the flash before flashing."
read -r -p "Run backup_gateway.sh now? [y/N] " do_backup
if [[ "$do_backup" =~ ^[yY]$ ]]; then
    "${SCRIPT_DIR}/backup_gateway.sh"
    echo ""
    echo "Backup complete. Put the gateway in download mode, then re-run this script."
    exit 0
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --boot-ip|--ip) shift; BOOT_IP="$1" ;;
        --help|-h)
            echo "Usage: $0 [--boot-ip ADDRESS]"
            echo "Flashes all 4 partitions (auto-detects bootloader type)."
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
KERNEL_R6CR=""
cleanup() {
    rm -f "$ETH0_CONF" "$RADIO_CONF"
    [ -n "$KERNEL_R6CR" ] && rm -f "$KERNEL_R6CR"
}
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

IFACE="$(ip route get "$BOOT_IP" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
if [ -z "${IFACE:-}" ]; then
    echo "Error: cannot determine outgoing interface to ${BOOT_IP}." >&2
    exit 1
fi
if ip route get "$BOOT_IP" 2>/dev/null | grep -qE '\svia\s'; then
    echo "Error: ${BOOT_IP} is reached via a gateway (routed). Must be same L2 segment." >&2
    exit 1
fi

# Wait for bootloader to respond on the network (ARP probe via UDP poke)
# Args: max_tries [message]
wait_for_bootloader() {
    local max_tries="${1:-10}" msg="${2:-Checking if gateway is in boot mode...}"
    local port="${PORT:-69}" sleep_between="${SLEEP_BETWEEN:-0.2}"
    echo "$msg"
    for _ in $(seq 1 "$max_tries"); do
        bash -c 'echo -n X > /dev/udp/'"$BOOT_IP"'/'"$port"'' >/dev/null 2>&1 || true
        sleep 0.2
        LINE="$(ip neigh show "$BOOT_IP" dev "$IFACE" 2>/dev/null || true)"
        if echo "$LINE" | grep -qiE 'lladdr [0-9a-f]{2}(:[0-9a-f]{2}){5}'; then
            return 0
        fi
        sleep "$sleep_between"
    done
    return 1
}

if ! wait_for_bootloader 10 "Checking if gateway is in boot mode..."; then
    echo "Error: ${BOOT_IP} not detected — is the device in download mode?" >&2
    exit 1
fi

# --- Detect bootloader type ------------------------------------------------
# Custom bootloaders (V1.2+) respond to ICMP ping. The original Tuya bootloader
# does not. This determines the flash order and confirmation method.

BOOTLOADER_TYPE="tuya"
if ping -c 1 -W 2 "$BOOT_IP" >/dev/null 2>&1; then
    BOOTLOADER_TYPE="custom"
fi

NOTIFY_PORT=9999

# --- TFTP error check helper -----------------------------------------------

check_tftp_error() {
    local out="$1"
    echo "$out" | grep -qiE \
        "error|timeout|timed out|refused|failed|unknown host|access denied|disk full|illegal|not connected|unknown transfer"
}

# ==========================================================================
#  CUSTOM BOOTLOADER (V1.2 / V2) — boot first, UDP notifications
# ==========================================================================

flash_custom() {
    echo "Custom bootloader detected (responds to ping)."
    echo ""
    echo "Ready to flash 4 partitions to ${BOOT_IP}."
    echo "Order: bootloader → rootfs → userdata → kernel (reboot)"
    echo ""
    read -r -p "Proceed? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then echo "Aborted."; exit 0; fi

    # Helper: flash one image and wait for bootloader UDP notification
    # Args: label dir file tftp_timeout notify_timeout
    flash_image_udp() {
        local label="$1" dir="$2" file="$3" tftp_tmo="$4" notify_tmo="$5"
        echo ""
        echo "Flashing ${label}..."

        # Start UDP listener BEFORE tftp (so we don't miss the notification)
        local notify_file
        notify_file=$(mktemp)
        (timeout "$notify_tmo" nc -u -l -p "$NOTIFY_PORT" -w 1 > "$notify_file" 2>/dev/null) &
        local nc_pid=$!
        sleep 0.2  # let nc bind the port

        cd "$dir"
        out=$(timeout "$tftp_tmo" tftp -m binary "$BOOT_IP" -c put "$file" 2>&1) || true
        cd "$SCRIPT_DIR"
        if check_tftp_error "$out"; then
            kill "$nc_pid" 2>/dev/null; wait "$nc_pid" 2>/dev/null
            rm -f "$notify_file"
            echo "Error: transfer failed: $out" >&2
            exit 1
        fi
        echo "${label} uploaded. Waiting for flash write..."

        # Wait for bootloader notification
        wait "$nc_pid" 2>/dev/null || true
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
            echo "This is normal with V1.2 bootloader (no UDP notification)." >&2
            echo "Check the serial console for 'Flash Write Succeeded!' status." >&2
            read -r -p "Continue? [y/N] " r
            if [[ ! "$r" =~ ^[yY]$ ]]; then echo "Aborted."; exit 1; fi
        fi
    }

    # --- Flash bootloader first -----------------------------------------------
    echo ""
    echo "Flashing bootloader..."
    notify_file=$(mktemp)
    (timeout 30 nc -u -l -p "$NOTIFY_PORT" -w 1 > "$notify_file" 2>/dev/null) &
    nc_pid=$!
    sleep 0.2

    cd "${RTL_DIR}/31-Bootloader"
    out=$(timeout 15 tftp -m binary "$BOOT_IP" -c put boot.bin 2>&1) || true
    cd "$SCRIPT_DIR"
    if check_tftp_error "$out"; then
        kill "$nc_pid" 2>/dev/null; wait "$nc_pid" 2>/dev/null
        rm -f "$notify_file"
        echo "Error: transfer failed: $out" >&2
        exit 1
    fi
    echo "Bootloader uploaded. Waiting for flash write..."

    wait "$nc_pid" 2>/dev/null || true
    result=$(tr -d '\0' < "$notify_file")
    rm -f "$notify_file"

    if [ "$result" = "OK" ]; then
        echo "Bootloader: Flash Write Succeeded."
    elif [ "$result" = "FAIL" ]; then
        echo "Error: bootloader flash write FAILED on gateway." >&2
        exit 1
    else
        echo "Warning: no notification received." >&2
        echo "Check the serial console for 'Flash Write Succeeded!' status." >&2
        read -r -p "Continue? [y/N] " r
        if [[ ! "$r" =~ ^[yY]$ ]]; then echo "Aborted."; exit 1; fi
    fi

    # --- Flash remaining partitions -------------------------------------------
    flash_image_udp "rootfs"     "${RTL_DIR}/33-Rootfs"     "rootfs.bin"   30  60
    flash_image_udp "userdata"   "${RTL_DIR}/34-Userdata"   "userdata.bin" 120 180

    echo ""
    echo "Flashing kernel (auto-reboots on success)..."
    notify_file=$(mktemp)
    (timeout 60 nc -u -l -p "$NOTIFY_PORT" -w 1 > "$notify_file" 2>/dev/null) &
    nc_pid=$!
    sleep 0.2
    cd "${RTL_DIR}/32-Kernel"
    out=$(timeout 30 tftp -m binary "$BOOT_IP" -c put kernel.img 2>&1) || true
    cd "$SCRIPT_DIR"
    if check_tftp_error "$out"; then
        kill "$nc_pid" 2>/dev/null; wait "$nc_pid" 2>/dev/null
        rm -f "$notify_file"
        echo "Error: transfer failed: $out" >&2
        exit 1
    fi
    echo "Kernel uploaded. Waiting for flash write..."
    wait "$nc_pid" 2>/dev/null || true
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
}

# ==========================================================================
#  TUYA BOOTLOADER (original) — boot last, r6cr wrapper, serial console
# ==========================================================================

flash_tuya() {
    echo "Original Tuya bootloader detected (no ping response)."
    echo ""
    echo "WARNING: This mode requires a serial console connection to the gateway."
    echo "You must be able to see 'Flash Write Succeeded!' messages on the console."
    echo ""
    read -r -p "Serial console is connected and ready? [y/N] " serial_ok
    if [[ ! "$serial_ok" =~ ^[yY]$ ]]; then echo "Aborted."; exit 0; fi

    if ! command -v python3 >/dev/null 2>&1; then
        echo "Error: python3 is required to re-wrap the kernel image." >&2
        exit 1
    fi

    # --- Re-wrap kernel with r6cr header (reboot=0) ----------------------------
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

    echo ""
    echo "Ready to flash 4 partitions to ${BOOT_IP}."
    echo "Order: rootfs → userdata → kernel → bootloader (reboot)"
    echo ""
    echo "After each upload, wait for 'Flash Write Succeeded!' on the serial"
    echo "console before confirming."
    echo ""
    read -r -p "Proceed? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then echo "Aborted."; exit 0; fi

    # Helper: flash one image and wait for serial confirmation
    # Args: label dir file timeout_seconds
    flash_image_serial() {
        local label="$1" dir="$2" file="$3" tmo="$4"
        echo ""
        echo "Flashing ${label}..."
        cd "$dir"
        out=$(timeout "$tmo" tftp -m binary "$BOOT_IP" -c put "$file" 2>&1) || true
        cd "$SCRIPT_DIR"
        if check_tftp_error "$out"; then
            echo "Error: transfer failed: $out" >&2
            exit 1
        fi
        echo "${label} uploaded."
        read -r -p "Flash Write Succeeded on serial console? [y/N] " r
        if [[ ! "$r" =~ ^[yY]$ ]]; then echo "Aborted."; exit 1; fi
    }

    flash_image_serial "rootfs"     "${RTL_DIR}/33-Rootfs"     "rootfs.bin"         30
    echo "Note: userdata is 12 MB — transfer and flash may take 1-2 minutes."
    flash_image_serial "userdata"   "${RTL_DIR}/34-Userdata"   "userdata.bin"       120
    flash_image_serial "kernel"     "${RTL_DIR}/32-Kernel"     "$KERNEL_R6CR_NAME"  30

    echo ""
    echo "Flashing bootloader (gateway will reboot after this)..."
    cd "${RTL_DIR}/31-Bootloader"
    out=$(timeout 15 tftp -m binary "$BOOT_IP" -c put boot.bin 2>&1) || true
    cd "$SCRIPT_DIR"
    if check_tftp_error "$out"; then
        echo "Error: transfer failed: $out" >&2
        exit 1
    fi
    echo ""
    echo "Done. Gateway will reboot with the new firmware."
}

# --- Main -----------------------------------------------------------------

if [ "$BOOTLOADER_TYPE" = "custom" ]; then
    flash_custom
else
    flash_tuya
fi
