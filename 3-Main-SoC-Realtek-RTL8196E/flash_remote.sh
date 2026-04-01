#!/bin/bash
# flash_remote.sh — Remote flash via SSH + boothold + TFTP
#
# Connects to the gateway over SSH, sends it to bootloader mode,
# waits for the bootloader to become reachable, then runs the
# appropriate flash script.
#
# Requires custom firmware with devmem (>= v1.2.1). Does NOT work on
# Tuya/Lidl stock firmware or v1.0 (no boothold capability).
#
# Usage: ./flash_remote.sh [-y] <component> <LINUX_IP>
#   component - bootloader | kernel | rootfs | userdata
#   LINUX_IP  - Gateway IP when Linux is running (required)
#
# Options:
#   -y, --yes   Non-interactive mode: skip all confirmation prompts
#
# Environment variables (optional overrides):
#   BOOT_IP     - Gateway IP in bootloader mode (default: 192.168.1.6)
#   SSH_USER    - SSH username (default: root)
#   SSH_TIMEOUT - TCP probe timeout in seconds (default: 2)
#   NET_MODE    - "static" or "dhcp" (skip network prompt, userdata only)
#   RADIO_MODE  - "zigbee" or "thread" (skip radio prompt, userdata only)
#   CONFIRM     - Set to "y" to skip confirmation prompts (same as -y)
#
# J. Nilo - March 2026

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- argument parsing --------------------------------------------------------

COMPONENT=""
LINUX_IP=""
BOOT_IP="${BOOT_IP:-192.168.1.6}"
SSH_USER="${SSH_USER:-root}"
SSH_TIMEOUT="${SSH_TIMEOUT:-2}"

usage() {
    echo "Usage: $0 [-y] <bootloader|kernel|rootfs|userdata> <LINUX_IP>"
    echo ""
    echo "Flashes a single partition via SSH + boothold + TFTP."
    echo "Requires custom firmware with devmem (>= v1.2.1)."
    echo ""
    echo "Arguments:"
    echo "  component   bootloader | kernel | rootfs | userdata"
    echo "  LINUX_IP    Gateway IP when running Linux (required)"
    echo ""
    echo "Options:"
    echo "  -y, --yes   Non-interactive mode (skip all prompts)"
    echo ""
    echo "Environment: BOOT_IP (default: 192.168.1.6), SSH_USER, SSH_TIMEOUT,"
    echo "  NET_MODE, RADIO_MODE, CONFIRM"
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes) CONFIRM="y" ;;
        --help|-h) usage ;;
        --*) echo "Unknown option: $1. Use --help for usage." >&2; exit 1 ;;
        *)
            if [ -z "$COMPONENT" ]; then
                COMPONENT="$1"
            elif [ -z "$LINUX_IP" ]; then
                LINUX_IP="$1"
            else
                echo "Error: unexpected argument '$1'." >&2
                usage
            fi
            ;;
    esac
    shift
done

# Validate component
case "$COMPONENT" in
    bootloader) FLASH_DIR="${SCRIPT_DIR}/31-Bootloader"; FLASH_SCRIPT="flash_bootloader.sh" ;;
    kernel)     FLASH_DIR="${SCRIPT_DIR}/32-Kernel";     FLASH_SCRIPT="flash_kernel.sh" ;;
    rootfs)     FLASH_DIR="${SCRIPT_DIR}/33-Rootfs";     FLASH_SCRIPT="flash_rootfs.sh" ;;
    userdata)   FLASH_DIR="${SCRIPT_DIR}/34-Userdata";   FLASH_SCRIPT="flash_userdata.sh" ;;
    *)          usage ;;
esac

# LINUX_IP is required
if [ -z "$LINUX_IP" ]; then
    echo "Error: LINUX_IP is required." >&2
    usage
fi

if [ ! -f "${FLASH_DIR}/${FLASH_SCRIPT}" ]; then
    echo "Error: ${FLASH_DIR}/${FLASH_SCRIPT} not found." >&2
    exit 1
fi

# --- helpers ------------------------------------------------------------------

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

# --- step 1: detect gateway state -------------------------------------------

echo "Probing SSH on ${LINUX_IP}..."

SSH_PORT=""
if timeout "$SSH_TIMEOUT" bash -c "echo >/dev/tcp/$LINUX_IP/22" 2>/dev/null; then
    SSH_PORT=22
elif timeout "$SSH_TIMEOUT" bash -c "echo >/dev/tcp/$LINUX_IP/2333" 2>/dev/null; then
    echo "Error: Tuya firmware detected (port 2333). This script requires custom firmware." >&2
    echo "For Tuya/first flash, use:  flash_install_rtl8196e.sh" >&2
    exit 1
else
    echo "Error: cannot reach gateway at ${LINUX_IP} (no SSH on port 22 or 2333)." >&2
    echo "If already in bootloader mode, use the flash script directly:" >&2
    echo "  cd ${FLASH_DIR} && ./${FLASH_SCRIPT} ${BOOT_IP}" >&2
    exit 1
fi

echo "Gateway is running Linux at ${LINUX_IP}:${SSH_PORT}."

# --- step 2: verify SSH access + devmem -------------------------------------

SSH_SOCK="/tmp/remote_flash_ssh_$$"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o ControlMaster=auto -o ControlPath=$SSH_SOCK -o ControlPersist=60 -p $SSH_PORT"

# Verify SSH access (opens ControlMaster connection)
# shellcheck disable=SC2086
if ! ssh $SSH_OPTS "${SSH_USER}@${LINUX_IP}" "true" 2>/dev/null; then
    echo "Error: SSH authentication failed." >&2
    exit 1
fi

# This script requires custom firmware with devmem (>= v1.2.1)
# devmem absent = Tuya or v1.0 firmware — cannot boothold
# shellcheck disable=SC2086
if ! ssh $SSH_OPTS "${SSH_USER}@${LINUX_IP}" "command -v devmem" >/dev/null 2>&1; then
    echo "Error: devmem not found — this firmware does not support boothold." >&2
    echo "For Tuya/first flash, use:  flash_install_rtl8196e.sh" >&2
    exit 1
fi

# --- step 3: preserve config before reboot (userdata only) ------------------

CONFIG_PRESERVED=""
if [ "$COMPONENT" = "userdata" ]; then
    # Work on a temporary copy of the skeleton — never modify the original
    SKEL_WORK=$(mktemp -d)
    cp -a "${FLASH_DIR}/skeleton/." "$SKEL_WORK/"
    trap 'rm -rf "$SKEL_WORK"' EXIT
    export SKELETON_DIR="$SKEL_WORK"

    SAVE_TAR=$(mktemp)
    # Save only user-configurable files (not init scripts or system files)
    SAVE_FILES="etc/eth0.conf etc/mac_address etc/radio.conf etc/leds.conf etc/passwd etc/TZ etc/hostname etc/dropbear ssh thread"
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "${SSH_USER}@${LINUX_IP}" \
        "tar cf - -C /userdata $SAVE_FILES 2>/dev/null" > "$SAVE_TAR" 2>/dev/null || true

    if [ -s "$SAVE_TAR" ]; then
        tar xf "$SAVE_TAR" -C "$SKEL_WORK" 2>/dev/null || true
        echo "Gateway config saved."
        CONFIG_PRESERVED=true
    else
        echo "Warning: could not save config from gateway."
    fi
    rm -f "$SAVE_TAR"
fi

# --- step 4: send boothold + reboot ------------------------------------------

echo "Sending boothold + reboot..."
# boothold writes HOLD to DRAM via pwrite+O_SYNC (bypasses write-back cache)
# BusyBox reboot signals init and returns — SSH session closes cleanly
# shellcheck disable=SC2086
ssh $SSH_OPTS "${SSH_USER}@${LINUX_IP}" "boothold && reboot" 2>/dev/null || true
# Close ControlMaster socket — gateway is rebooting, stale connection
# would interfere with shutdown detection
ssh -O exit -o ControlPath="$SSH_SOCK" "${SSH_USER}@${LINUX_IP}" 2>/dev/null || true

# --- step 5: wait for bootloader -------------------------------------------
# Two-phase wait to avoid ARP false positives (Linux responds to ARP for
# BOOT_IP via ARP flux while still shutting down).

IFACE="$(ip route get "$BOOT_IP" 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
if [ -z "${IFACE:-}" ]; then
    echo "Error: cannot determine outgoing interface to ${BOOT_IP}." >&2
    exit 1
fi

# Phase 1: wait for SSH to go down (Linux is shutting down)
echo "Waiting for shutdown..."
tries=0
while [ $tries -lt 15 ]; do
    if ! timeout 1 bash -c "echo >/dev/tcp/$LINUX_IP/$SSH_PORT" 2>/dev/null; then
        break
    fi
    sleep 1
    tries=$((tries + 1))
done

# Phase 2: wait for bootloader ARP
echo "Waiting for bootloader at ${BOOT_IP}..."
tries=0
while [ $tries -lt 30 ]; do
    ip neigh del "$BOOT_IP" dev "$IFACE" 2>/dev/null || true
    bash -c "echo -n X >/dev/udp/$BOOT_IP/69" 2>/dev/null || true
    sleep 1
    nei="$(ip neigh show "$BOOT_IP" dev "$IFACE" 2>/dev/null || true)"
    if echo "$nei" | grep -Eqi 'lladdr [0-9a-f]{2}(:[0-9a-f]{2}){5}'; then
        break
    fi
    tries=$((tries + 1))
    if [ $((tries % 5)) -eq 0 ]; then
        echo "  ...${tries}s"
    fi
done

if [ $tries -ge 30 ]; then
    echo "Error: bootloader not reachable after 30s." >&2
    echo "Check that boothold worked and the gateway rebooted." >&2
    exit 1
fi
echo "Bootloader is up."

# --- step 6: run flash script -----------------------------------------------

cd "$FLASH_DIR"
export BUILD_QUIET=1
export BOOTLOADER_CONFIRMED=1
if [ "${CONFIRM:-}" = "y" ]; then
    export CONFIRM=y
fi
if [ "$COMPONENT" = "userdata" ]; then
    if [ "${CONFIG_PRESERVED:-}" = "true" ]; then
        export NET_MODE="skip"
        export RADIO_MODE="skip"
    else
        export NET_MODE="${NET_MODE:-static}"
        export RADIO_MODE="${RADIO_MODE:-zigbee}"
    fi
fi
./"$FLASH_SCRIPT" "$BOOT_IP"
