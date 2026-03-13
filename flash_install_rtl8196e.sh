#!/bin/bash
# flash_install_rtl8196e.sh — Install custom firmware on Lidl Silvercrest Gateway
#
# Builds a fullflash.bin image (via build_fullflash.sh) and uploads it to the
# gateway via TFTP. The gateway must be in bootloader mode (<RealTek> prompt).
#
# Works with any bootloader version:
#   - V2 custom bootloader: auto-flashes on receiving a 16 MiB file
#   - Older bootloaders (Tuya, V1.2): guided LOADADDR + FLW via serial console
#
# Prerequisites:
#   - Serial console connected (3.3V UART, 38400 baud)
#   - Gateway in bootloader mode (press ESC during boot or use boothold)
#   - Ethernet cable between host and gateway
#   - tftp-hpa client installed (sudo apt install tftp-hpa)
#
# Usage: ./flash_install_rtl8196e.sh [--boot-ip IP] [--help]
#
# Environment variables (for non-interactive use):
#   BOOT_IP     - Gateway IP in bootloader (default: 192.168.1.6)
#   NET_MODE    - "static" or "dhcp" (skip network prompt)
#   IPADDR      - Static IP address (default: 192.168.1.88)
#   NETMASK     - Netmask (default: 255.255.255.0)
#   GATEWAY     - Default gateway (default: 192.168.1.1)
#   RADIO_MODE  - "zigbee" or "thread" (skip radio prompt)
#   CONFIRM     - Set to "y" to skip confirmation prompts
#
# J. Nilo - March 2026

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINUX_IP="${LINUX_IP:-192.168.1.88}"
BOOT_IP="${BOOT_IP:-192.168.1.6}"

# --- argument parsing --------------------------------------------------------

while [ $# -gt 0 ]; do
    case "$1" in
        --boot-ip|--ip) shift; BOOT_IP="$1" ;;
        --help|-h)
            echo "Usage: $0 [--boot-ip IP] [--help]"
            echo ""
            echo "Installs custom firmware on the Lidl Silvercrest Gateway."
            echo "The gateway must be in bootloader mode (<RealTek> prompt)."
            echo ""
            echo "Options:"
            echo "  --boot-ip IP   Gateway IP in bootloader (default: 192.168.1.6)"
            echo ""
            echo "Environment: BOOT_IP, NET_MODE, RADIO_MODE, CONFIRM,"
            echo "  IPADDR, NETMASK, GATEWAY"
            exit 0
            ;;
        *) echo "Unknown option: $1. Use --help for usage."; exit 1 ;;
    esac
    shift
done

# --- prerequisites -----------------------------------------------------------

# Check tftp-hpa client
tftp_usage="$(tftp --help 2>&1 || true)"
if ! command -v tftp >/dev/null 2>&1 || ! echo "$tftp_usage" | grep -q '\-c'; then
    echo "Error: tftp-hpa client not found (need the -c flag)." >&2
    echo "Install it with: sudo apt install tftp-hpa" >&2
    exit 1
fi


# --- detect bootloader (early — fail fast before building) -------------------

echo ""
echo "========================================="
echo "  FIRMWARE INSTALLATION"
echo "========================================="
echo ""

echo "Checking for bootloader at ${BOOT_IP}..."

IFACE="$(ip route get "$BOOT_IP" 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
if [ -z "${IFACE:-}" ]; then
    echo "Error: cannot determine outgoing interface to ${BOOT_IP}." >&2
    exit 1
fi

# Check if Linux is running (SSH on BOOT_IP or LINUX_IP) — means NOT in bootloader
LINUX_RUNNING=""
if timeout 1 bash -c "echo >/dev/tcp/$BOOT_IP/22" 2>/dev/null; then
    LINUX_RUNNING="custom:${BOOT_IP}:22"
elif timeout 1 bash -c "echo >/dev/tcp/$BOOT_IP/2333" 2>/dev/null; then
    LINUX_RUNNING="tuya:${BOOT_IP}:2333"
elif [ "$LINUX_IP" != "$BOOT_IP" ]; then
    if timeout 1 bash -c "echo >/dev/tcp/$LINUX_IP/22" 2>/dev/null; then
        LINUX_RUNNING="custom:${LINUX_IP}:22"
    fi
fi

if [ -n "$LINUX_RUNNING" ]; then
    fw_type="${LINUX_RUNNING%%:*}"
    fw_host="$(echo "$LINUX_RUNNING" | cut -d: -f2)"
    fw_port="$(echo "$LINUX_RUNNING" | cut -d: -f3)"
    echo "Linux detected at ${fw_host}:${fw_port} (${fw_type} firmware)."

    # --- propose backup (while Linux is still running) -----------------------
    if [ "${CONFIRM:-}" != "y" ]; then
        echo ""
        echo "It is recommended to back up the flash before installing."
        read -r -p "Run backup_gateway.sh now? [y/N] " do_backup
        if [[ "$do_backup" =~ ^[yY]$ ]]; then
            "${SCRIPT_DIR}/backup_gateway.sh" --linux-ip "$fw_host" --boot-ip "$BOOT_IP"
            echo ""
        fi
    fi

    if [ "$fw_type" = "custom" ]; then
        echo "Sending boothold + reboot..."
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 \
            "root@${fw_host}" "devmem 0x003FFFFC 32 0x484F4C44 && reboot" 2>/dev/null || true
    else
        echo ""
        echo "Tuya firmware detected. Cannot boothold automatically."
        echo "To enter bootloader mode:"
        echo "  - Connect serial console (3.3V UART, 38400 baud)"
        echo "  - Power cycle the gateway"
        echo "  - Press ESC repeatedly during boot to get the <RealTek> prompt"
        echo "  - Then re-run:  $0 --boot-ip <BOOTLOADER_IP>"
        echo ""
        echo "Note: the bootloader IP is usually 192.168.1.6 (default)."
        echo "It may differ from the Linux IP (${fw_host})."
        echo ""
        exit 1
    fi

    echo "Waiting for bootloader at ${BOOT_IP}..."
    tries=0
    while [ $tries -lt 30 ]; do
        ip neigh del "$BOOT_IP" dev "$IFACE" 2>/dev/null || true
        bash -c "echo -n X >/dev/udp/$BOOT_IP/69" 2>/dev/null || true
        sleep 1
        nei="$(ip neigh show "$BOOT_IP" dev "$IFACE" 2>/dev/null || true)"
        if echo "$nei" | grep -Eqi 'lladdr [0-9a-f]{2}(:[0-9a-f]{2}){5}'; then
            # Confirm it's really bootloader (SSH must be down now)
            if ! timeout 1 bash -c "echo >/dev/tcp/$BOOT_IP/22" 2>/dev/null && \
               ! timeout 1 bash -c "echo >/dev/tcp/$BOOT_IP/2333" 2>/dev/null; then
                break
            fi
        fi
        tries=$((tries + 1))
    done

    if [ $tries -ge 30 ]; then
        echo "Error: bootloader not detected after boothold." >&2
        exit 1
    fi
else
    # No Linux (SSH) — check if bootloader is reachable via ARP
    ip neigh del "$BOOT_IP" dev "$IFACE" 2>/dev/null || true
    bash -c "echo -n X >/dev/udp/$BOOT_IP/69" 2>/dev/null || true
    sleep 0.3

    nei="$(ip neigh show "$BOOT_IP" dev "$IFACE" 2>/dev/null || true)"
    if ! echo "$nei" | grep -Eqi 'lladdr [0-9a-f]{2}(:[0-9a-f]{2}){5}'; then
        echo "Bootloader not detected at ${BOOT_IP}."
        echo ""
        echo "To enter bootloader mode:"
        echo "  - Connect serial console (3.3V UART, 38400 baud)"
        echo "  - Power cycle the gateway"
        echo "  - Press ESC repeatedly during boot to get the <RealTek> prompt"
        echo "  - Then re-run:  $0 --boot-ip <BOOTLOADER_IP>"
        echo ""
        echo "Note: the bootloader IP is usually 192.168.1.6 (default)."
        echo "It may differ from the Linux IP (${BOOT_IP})."
        echo ""
        exit 1
    fi

    # ARP resolved + no SSH = bootloader (either V2 with ping or old without).
fi

# Detect bootloader type: V2 custom responds to ping, older ones don't.
BOOTLOADER_TYPE="old"
if ping -c 1 -W 2 "$BOOT_IP" >/dev/null 2>&1; then
    BOOTLOADER_TYPE="v2"
fi

echo "Bootloader detected at ${BOOT_IP} (type: ${BOOTLOADER_TYPE})."

# If we reached bootloader without going through Linux (no backup opportunity),
# warn the user.
if [ -z "$LINUX_RUNNING" ] && [ "${CONFIRM:-}" != "y" ]; then
    echo ""
    echo "WARNING: No backup was made. To back up first, boot the gateway"
    echo "into Linux and run:  ./backup_gateway.sh"
    echo ""
    read -r -p "Continue without backup? [y/N] " do_continue
    if [[ ! "$do_continue" =~ ^[yY]$ ]]; then
        echo "Aborted."
        exit 0
    fi
fi

# --- build fullflash.bin -----------------------------------------------------

echo ""
"${SCRIPT_DIR}/build_fullflash.sh"

FULLFLASH="${SCRIPT_DIR}/fullflash.bin"
if [ ! -f "$FULLFLASH" ]; then
    echo "Error: fullflash.bin not found after build." >&2
    exit 1
fi

FLASH_SIZE=$((16 * 1024 * 1024))
ff_size=$(stat -c%s "$FULLFLASH")
if [ "$ff_size" -ne "$FLASH_SIZE" ]; then
    echo "Error: fullflash.bin is ${ff_size} bytes (expected ${FLASH_SIZE})." >&2
    exit 1
fi

# --- confirm -----------------------------------------------------------------

echo ""
echo "WARNING: This will overwrite the ENTIRE flash chip (16 MiB)."
echo "All data on the gateway will be replaced."
echo ""
echo "  Image:  fullflash.bin ($(md5sum "$FULLFLASH" | awk '{print $1}'))"
echo "  Target: ${BOOT_IP} (${BOOTLOADER_TYPE} bootloader)"
echo ""

if [ "${CONFIRM:-}" != "y" ]; then
    read -r -p "Proceed? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then echo "Aborted."; exit 0; fi
fi

# --- flash (step by step) ----------------------------------------------------

if [ ! -t 0 ]; then
    echo "Error: this script requires an interactive terminal (serial console guidance)." >&2
    exit 1
fi

check_tftp_error() {
    echo "$1" | grep -qiE \
        "error|timeout|timed out|refused|failed|unknown host|access denied|disk full|illegal|not connected|unknown transfer"
}

if [ "$BOOTLOADER_TYPE" = "v2" ]; then
    # --- V2 bootloader: upload + auto-flash -----------------------------------
    echo ""
    echo "Uploading fullflash.bin via TFTP (16 MiB)..."
    cd "$SCRIPT_DIR"
    out=$(timeout 300 tftp -m binary "$BOOT_IP" -c put fullflash.bin 2>&1) || true

    if check_tftp_error "$out"; then
        echo "Error: TFTP transfer failed: $out" >&2
        exit 1
    fi
    echo "Upload OK. Waiting for auto-flash notification (10s)..."

    # Wait for UDP notification (OK or FAIL) on port 9999
    # V2.3+ bootloaders auto-flash and notify within seconds.
    # Older V2 bootloaders send FAIL or nothing — short timeout to avoid blocking.
    result=""
    if command -v nc >/dev/null 2>&1; then
        notify_file=$(mktemp)
        (timeout 10 nc -u -l -p 9999 > "$notify_file" 2>/dev/null) &
        nc_pid=$!

        while kill -0 "$nc_pid" 2>/dev/null; do
            [ -s "$notify_file" ] && { kill "$nc_pid" 2>/dev/null; break; }
            sleep 0.5
        done
        wait "$nc_pid" 2>/dev/null || true
        result=$(tr -d '\0' < "$notify_file" 2>/dev/null || true)
        rm -f "$notify_file"
    fi

    if [ "$result" = "OK" ]; then
        echo ""
        echo "========================================="
        echo "  INSTALLATION COMPLETE"
        echo "========================================="
        echo ""
        echo "Flash write succeeded. The gateway will reboot automatically."
        echo "SSH: root@${LINUX_IP}:22 (no password) in ~30 seconds."
    else
        # Auto-flash failed or no notification — fallback to manual FLW
        if [ "$result" = "FAIL" ]; then
            echo "Auto-flash reported FAIL. Falling back to manual flash."
        else
            echo "No auto-flash notification. Falling back to manual flash."
        fi
        echo ""
        echo "The image is in the gateway's RAM. On the serial console, type:"
        echo ""
        echo "    FLW 0 80500000 01000000 0"
        echo ""
        echo "Wait for the <RealTek> prompt (takes ~2 minutes)."
        echo ""
        read -r -p "Flash Write Succeeded? [y/N] " r
        if [[ ! "$r" =~ ^[yY]$ ]]; then echo "Aborted."; exit 1; fi

        echo ""
        echo "On the serial console, type:  reboot"
        echo ""
        echo "========================================="
        echo "  INSTALLATION COMPLETE"
        echo "========================================="
        echo ""
        echo "SSH: root@${LINUX_IP}:22 (no password) in ~30 seconds."
    fi

else
    # --- Older bootloader: LOADADDR + upload + FLW ----------------------------
    if [ ! -t 0 ]; then
        echo "Error: this script requires an interactive terminal." >&2
        exit 1
    fi

    echo ""
    echo "--- Step 1: upload ---"
    echo ""
    cd "$SCRIPT_DIR"
    out=$(timeout 300 tftp -m binary "$BOOT_IP" -c put fullflash.bin 2>&1) || true

    if check_tftp_error "$out"; then
        echo "Error: TFTP transfer failed: $out" >&2
        exit 1
    fi
    echo "Upload OK."

    echo ""
    echo "--- Step 2: write to flash ---"
    echo ""
    echo "On the serial console, type:"
    echo ""
    echo "    FLW 0 80500000 01000000 0"
    echo ""
    echo "Wait for the <RealTek> prompt (takes ~2 minutes)."
    echo ""
    read -r -p "Flash Write Succeeded? [y/N] " r
    if [[ ! "$r" =~ ^[yY]$ ]]; then echo "Aborted."; exit 1; fi

    echo ""
    echo "--- Step 3: reboot ---"
    echo ""
    echo "On the serial console, type:  reboot"
    echo ""
    echo "========================================="
    echo "  INSTALLATION COMPLETE"
    echo "========================================="
    echo ""
    echo "SSH: root@${LINUX_IP}:22 (no password) in ~30 seconds."
fi
