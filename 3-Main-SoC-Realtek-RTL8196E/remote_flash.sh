#!/bin/bash
# remote_flash.sh — Remote flash via SSH + boothold + TFTP
#
# Connects to the gateway over SSH, sends it to bootloader mode,
# waits for the bootloader to become reachable, then runs the
# appropriate flash script.
#
# Usage: ./remote_flash.sh <component> [LINUX_IP] [BOOT_IP]
#   component - bootloader | kernel | rootfs | userdata
#   LINUX_IP  - Gateway IP when Linux is running (default: 192.168.1.88)
#   BOOT_IP   - Gateway IP in bootloader mode    (default: 192.168.1.6)
#
# Environment variables (optional overrides):
#   SSH_USER   - SSH username (default: root)
#   SSH_OPTS   - Extra SSH options (default: -o ConnectTimeout=5)
#
# J. Nilo - March 2026

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- arguments ----------------------------------------------------------------

COMPONENT="${1:-}"
LINUX_IP="${2:-192.168.1.88}"
BOOT_IP="${3:-192.168.1.6}"

SSH_USER="${SSH_USER:-root}"
SSH_OPTS="${SSH_OPTS:--o ConnectTimeout=5}"

usage() {
    echo "Usage: $0 <bootloader|kernel|rootfs|userdata> [LINUX_IP] [BOOT_IP]"
    echo "  LINUX_IP  default: 192.168.1.88"
    echo "  BOOT_IP   default: 192.168.1.6"
    exit 1
}

case "$COMPONENT" in
    bootloader) FLASH_DIR="${SCRIPT_DIR}/31-Bootloader"; FLASH_SCRIPT="flash_bootloader.sh" ;;
    kernel)     FLASH_DIR="${SCRIPT_DIR}/32-Kernel";     FLASH_SCRIPT="flash_kernel.sh" ;;
    rootfs)     FLASH_DIR="${SCRIPT_DIR}/33-Rootfs";     FLASH_SCRIPT="flash_rootfs.sh" ;;
    userdata)   FLASH_DIR="${SCRIPT_DIR}/34-Userdata";   FLASH_SCRIPT="flash_userdata.sh" ;;
    *)          usage ;;
esac

if [ ! -f "${FLASH_DIR}/${FLASH_SCRIPT}" ]; then
    echo "Error: ${FLASH_DIR}/${FLASH_SCRIPT} not found." >&2
    exit 1
fi

# --- helpers ------------------------------------------------------------------

# Check if SSH port is open (gateway is running Linux)
ssh_reachable() {
    timeout 2 bash -c "echo >/dev/tcp/$LINUX_IP/22" 2>/dev/null
}

# Check if bootloader is reachable (ARP resolves on BOOT_IP)
bootloader_reachable() {
    local iface
    iface="$(ip route get "$BOOT_IP" 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
    [ -z "$iface" ] && return 1

    ip neigh del "$BOOT_IP" dev "$iface" 2>/dev/null || true
    bash -c "echo -n X >/dev/udp/$BOOT_IP/69" 2>/dev/null || true
    sleep 0.3

    local nei
    nei="$(ip neigh show "$BOOT_IP" dev "$iface" 2>/dev/null || true)"
    echo "$nei" | grep -Eqi 'lladdr [0-9a-f]{2}(:[0-9a-f]{2}){5}'
}

# --- step 1: check gateway state ---------------------------------------------

echo "Checking gateway state..."

if bootloader_reachable; then
    echo "Gateway is already in bootloader mode."
elif ssh_reachable; then
    echo "Gateway is running Linux at ${LINUX_IP}."

    # --- step 2: send boothold via SSH ----------------------------------------

    echo "Sending boothold..."
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "${SSH_USER}@${LINUX_IP}" "boothold" 2>/dev/null || true

    # --- step 3: wait for bootloader ------------------------------------------

    echo "Waiting for bootloader at ${BOOT_IP}..."
    WAIT_TMO=30
    ok=0
    for i in $(seq 1 "$WAIT_TMO"); do
        if bootloader_reachable; then
            ok=1
            break
        fi
        # Show progress every 5 seconds
        if [ $((i % 5)) -eq 0 ]; then
            echo "  ...${i}s"
        fi
        sleep 1
    done

    if [ "$ok" -ne 1 ]; then
        echo "Error: bootloader not reachable after ${WAIT_TMO}s." >&2
        echo "Check that boothold is installed and the gateway rebooted." >&2
        exit 1
    fi
    echo "Bootloader is up."
else
    echo "Error: gateway unreachable — neither SSH (${LINUX_IP}:22) nor bootloader (${BOOT_IP})." >&2
    exit 1
fi

# --- step 4: run flash script ------------------------------------------------

echo ""
cd "$FLASH_DIR"
export CONFIRM=y
if [ "$COMPONENT" = "userdata" ]; then
    # Defaults: static IP 192.168.1.88, Zigbee mode (serialgateway / uart-ncp-hw)
    export NET_MODE="${NET_MODE:-static}"
    export RADIO_MODE="${RADIO_MODE:-zigbee}"
fi
./"$FLASH_SCRIPT" "$BOOT_IP"
