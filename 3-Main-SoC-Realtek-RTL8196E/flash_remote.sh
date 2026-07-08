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
#   -y, --yes      Non-interactive mode: skip all confirmation prompts
#   --boot-ip <IP> Bootloader-mode / TFTP server IP. Overrides the BOOT_IP
#                  env var (precedence: flag > env > default 192.168.1.6).
#
# Environment variables (optional overrides):
#   BOOT_IP      - Gateway IP in bootloader mode (default: 192.168.1.6).
#                  Passed to boothold so the bootloader (V2.7+) comes up on
#                  this address in download mode — no serial IPCONFIG needed.
#                  The --boot-ip flag takes precedence when both are given.
#   SSH_TIMEOUT  - TCP probe timeout in seconds (default: 2)
#   SSH_PASSWORD - Root password for non-interactive auth (CI / no tty).
#                  When set, the first ssh call is fed via sshpass and the
#                  ControlMaster takes over for the rest. Requires sshpass
#                  (sudo apt install sshpass).
#   NET_MODE     - "static" or "dhcp" (skip network prompt, userdata only)
#   RADIO_MODE   - "zigbee" or "thread" (skip radio prompt, userdata only)
#   BOARD        - "lidl" (default) or "sengled-e39-g8c" (kernel and
#                  bootloader components — both have per-board pre-builts)
#   KERNEL       - "6.18" (default) or "7.1" (kernel component)
#   CONFIRM      - Set to "y" to skip confirmation prompts (same as -y)
#
# J. Nilo - March 2026

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source hardened SSH helpers (ssh_retry, SSH_HARDEN_OPTS, valid_ipv4).
# Sourced before argument parsing so valid_ipv4 can vet --boot-ip / BOOT_IP.
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../lib/ssh.sh"
# (board, kernel) validation + image resolver (kernel_image_validate).
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../lib/kernel_image.sh"

# --- argument parsing --------------------------------------------------------

COMPONENT=""
LINUX_IP=""
# BOOT_IP precedence: --boot-ip flag > BOOT_IP env > default. The flag is
# captured into BOOT_IP_FLAG during parsing and applied after the loop.
BOOT_IP="${BOOT_IP:-192.168.1.6}"
BOOT_IP_FLAG=""
# Optional kernel-image override, forwarded to flash_kernel.sh --image (e.g.
# --image kernel-img/lidl/kernel-7.1.img). Honored for the kernel component only.
IMAGE_OVERRIDE=""
# BOARD/KERNEL pick the pre-built kernel image (kernel component) and BOARD
# the pre-built bootloader (bootloader component), forwarded to the flash
# scripts. Defaults reproduce the Lidl 6.18 path.
# FORCE overrides the board-mismatch guard.
BOARD="${BOARD:-lidl}"
KERNEL="${KERNEL:-6.18}"
FORCE=0
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
    echo "  -y, --yes        Non-interactive mode (skip all prompts)"
    echo "  --boot-ip <IP|host>  Bootloader-mode / TFTP server IP (overrides BOOT_IP"
    echo "                   env; default: 192.168.1.6). A hostname is resolved host-side."
    echo "  --board <name>   Board image (kernel and bootloader components; default"
    echo "                   lidl; also sengled-e39-g8c). Overrides the BOARD env var."
    echo "  --kernel <line>  Kernel line (kernel component; default 6.18; also 7.1)."
    echo "                   Overrides the KERNEL env var."
    echo "  --image <file>   Explicit kernel image (kernel component; overrides"
    echo "                   --board/--kernel). E.g. --image kernel-img/lidl/kernel-7.1.img."
    echo "  --force          Skip the board-mismatch safety check."
    echo ""
    echo "Environment: BOOT_IP (default: 192.168.1.6), BOARD, KERNEL, SSH_TIMEOUT,"
    echo "  SSH_PASSWORD (sshpass), NET_MODE, RADIO_MODE, CONFIRM"
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes) CONFIRM="y" ;;
        --help|-h) usage ;;
        --boot-ip)
            shift
            [ $# -gt 0 ] || { echo "Error: --boot-ip requires an argument." >&2; exit 1; }
            BOOT_IP_FLAG="$1"
            ;;
        --boot-ip=*) BOOT_IP_FLAG="${1#*=}" ;;
        --image)
            shift
            [ $# -gt 0 ] || { echo "Error: --image requires an argument." >&2; exit 1; }
            IMAGE_OVERRIDE="$1"
            ;;
        --image=*) IMAGE_OVERRIDE="${1#*=}" ;;
        --board)
            shift
            [ $# -gt 0 ] || { echo "Error: --board requires an argument." >&2; exit 1; }
            BOARD="$1"
            ;;
        --board=*) BOARD="${1#*=}" ;;
        --kernel)
            shift
            [ $# -gt 0 ] || { echo "Error: --kernel requires an argument." >&2; exit 1; }
            KERNEL="$1"
            ;;
        --kernel=*) KERNEL="${1#*=}" ;;
        --force) FORCE=1 ;;
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

# Apply --boot-ip override (flag > env > default), resolving a hostname if one
# was given (the on-device boothold/bootloader need a literal IPv4 — resolve
# host-side). A dotted-quad passes through unchanged.
[ -n "$BOOT_IP_FLAG" ] && BOOT_IP="$BOOT_IP_FLAG"
if BOOT_IP_RESOLVED="$(resolve_ipv4 "$BOOT_IP")"; then
    [ "$BOOT_IP_RESOLVED" != "$BOOT_IP" ] && echo "Resolved BOOT_IP '$BOOT_IP' -> $BOOT_IP_RESOLVED"
    BOOT_IP="$BOOT_IP_RESOLVED"
else
    echo "Error: invalid BOOT_IP '$BOOT_IP' (not a dotted-quad IPv4, and could" >&2
    echo "not be resolved as a hostname)." >&2
    exit 1
fi

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

# Validate BOARD/KERNEL early (kernel component, no explicit --image) so a typo
# fails before we touch the gateway. flash_kernel.sh resolves the real image.
# For the bootloader component, also require the per-board pre-built boot.bin
# up-front — flash_bootloader.sh resolves the same path from BOARD.
if [ "$COMPONENT" = "kernel" ] && [ -z "$IMAGE_OVERRIDE" ]; then
    kernel_image_validate "$BOARD" "$KERNEL" || exit 1
elif [ "$COMPONENT" = "bootloader" ]; then
    resolve_boot_image "$BOARD" >/dev/null || exit 1
fi

# --- helpers ------------------------------------------------------------------

# Check if bootloader is reachable (ARP resolves on BOOT_IP)
bootloader_reachable() {
    local iface
    iface="$(ip route get "$BOOT_IP" 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)"
    [ -z "$iface" ] && return 1

    ip neigh del "$BOOT_IP" dev "$iface" 2>/dev/null || true
    bash -c "echo -n X >/dev/udp/$BOOT_IP/69" 2>/dev/null || true
    sleep 0.3

    local nei
    nei="$(ip neigh show "$BOOT_IP" dev "$iface" 2>/dev/null || true)"
    echo "$nei" | grep -Eqi 'lladdr [0-9a-f]{2}(:[0-9a-f]{2}){5}'
}

# check_board_match <board> — refuse to flash a kernel built for a different
# board than the one currently running. /proc/device-tree/model on the gateway
# identifies the hardware (set by the running DTB). cat runs on the gateway
# (BusyBox has no tr); the trailing NUL is stripped host-side. An unreadable or
# unrecognised model is non-fatal — warn and proceed rather than block the
# common path on an unexpected string. Returns non-zero only on a clear
# mismatch (caller exits unless --force).
check_board_match() {
    local want="$1" model sig
    model="$(ssh_retry "${SSH_OPTS[@]}" "$SSH_TARGET" "cat /proc/device-tree/model" 2>/dev/null | tr -d '\0' || true)"
    if [ -z "$model" ]; then
        echo "Note: could not read the gateway's board model — skipping board check." >&2
        return 0
    fi
    case "$want" in
        lidl)            sig="Lidl" ;;
        sengled-e39-g8c) sig="Sengled" ;;
        *)               return 0 ;;
    esac
    if printf '%s' "$model" | grep -q "$sig"; then
        return 0
    fi
    echo "Error: board mismatch — selected BOARD='$want', but the gateway reports:" >&2
    echo "         model = \"$model\"" >&2
    echo "  A kernel built for a different board will not boot correctly; a" >&2
    echo "  mismatched bootloader bricks the gateway (per-board DRAM bring-up)." >&2
    echo "  Re-run with the matching BOARD=, or pass --force to override." >&2
    return 1
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
# (SSH helpers were sourced near the top, before argument parsing.)

# sshpass is only required when SSH_PASSWORD is set (non-interactive
# password auth — see lib/ssh.sh:ssh_prime_with_password).
if [ -n "${SSH_PASSWORD:-}" ] && ! command -v sshpass >/dev/null 2>&1; then
    echo "Error: SSH_PASSWORD is set but sshpass is not installed." >&2
    echo "Install it with: sudo apt install sshpass" >&2
    exit 1
fi

# StrictHostKeyChecking=no + /dev/null known_hosts is intentional here:
# this workflow targets gateways that may have just been re-flashed, so
# host keys churn legitimately. ControlMaster comes from lib/ssh.sh, which
# also handles cleanup at exit (chained below).
SSH_OPTS=(
    "${SSH_HARDEN_OPTS[@]}"
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -p "$SSH_PORT"
)
SSH_TARGET="root@${LINUX_IP}"
trap 'ssh_cleanup_multiplex' EXIT

# Open the ControlMaster up-front using SSH_PASSWORD if provided
# (no-op when SSH_PASSWORD is unset — ssh's tty prompt handles it).
if ! ssh_prime_with_password "${SSH_OPTS[@]}" "$SSH_TARGET"; then
    exit 1
fi

# Verify SSH access (opens ControlMaster connection)
if ! ssh_retry "${SSH_OPTS[@]}" "$SSH_TARGET" "true" 2>/dev/null; then
    echo "Error: SSH authentication failed." >&2
    exit 1
fi

# This script requires custom firmware with devmem (>= v1.2.1)
# devmem absent = Tuya or v1.0 firmware — cannot boothold
if ! ssh_retry "${SSH_OPTS[@]}" "$SSH_TARGET" "command -v devmem" >/dev/null 2>&1; then
    echo "Error: devmem not found — this firmware does not support boothold." >&2
    echo "For Tuya/first flash, use:  flash_install_rtl8196e.sh" >&2
    exit 1
fi

# Board-mismatch guard (kernel component with no explicit --image, and the
# bootloader component — a mismatched bootloader bricks). --force skips it.
if [ "$FORCE" != "1" ]; then
    if { [ "$COMPONENT" = "kernel" ] && [ -z "$IMAGE_OVERRIDE" ]; } \
       || [ "$COMPONENT" = "bootloader" ]; then
        check_board_match "$BOARD" || exit 1
    fi
fi

# --- step 3: preserve config before reboot (userdata only) ------------------

CONFIG_PRESERVED=""
if [ "$COMPONENT" = "userdata" ]; then
    # Work on a temporary copy of the skeleton — never modify the original
    SKEL_WORK=$(mktemp -d)
    cp -a "${FLASH_DIR}/skeleton/." "$SKEL_WORK/"
    trap 'rm -rf "$SKEL_WORK"; ssh_cleanup_multiplex' EXIT
    export SKELETON_DIR="$SKEL_WORK"

    SAVE_TAR=$(mktemp)
    # Save user-configurable files (not init scripts or system files). Other
    # user-added paths under /userdata are preserved separately below.
    SAVE_FILES="etc/eth0.conf etc/mac_address etc/radio.conf etc/leds.conf etc/passwd etc/TZ etc/hostname etc/dropbear ssh thread"
    ssh_retry "${SSH_OPTS[@]}" "$SSH_TARGET" \
        "tar cf - -C /userdata $SAVE_FILES 2>/dev/null" > "$SAVE_TAR" 2>/dev/null || true

    if [ -s "$SAVE_TAR" ]; then
        tar xf "$SAVE_TAR" -C "$SKEL_WORK" 2>/dev/null || true
        echo "Gateway config saved."
        CONFIG_PRESERVED=true
    else
        echo "Warning: could not save config from gateway."
    fi
    rm -f "$SAVE_TAR"

    # Also carry any user-added paths under /userdata (custom programs, scripts,
    # whole new directories) — anything not shipped in the skeleton and not
    # already re-injected above — across the reflash.
    preserve_user_additions "$SKEL_WORK" "$SSH_TARGET" "${SSH_OPTS[@]}"
fi

# --- step 4: send boothold + reboot ------------------------------------------

echo "Sending boothold + reboot..."
# boothold writes HOLD to DRAM via pwrite+O_SYNC (bypasses write-back cache).
# Passing BOOT_IP makes the bootloader (V2.7+) come up on that same address in
# download mode — the IP we are about to connect to — so a non-default BOOT_IP
# needs no serial IPCONFIG. Older boothold/bootloaders ignore the argument and
# fall back to the compiled default (192.168.1.6).
# BusyBox reboot signals init and returns — SSH session closes cleanly
ssh_retry "${SSH_OPTS[@]}" "$SSH_TARGET" "boothold \"$BOOT_IP\" && reboot" 2>/dev/null || true
# Close ControlMaster socket — gateway is rebooting, stale connection
# would interfere with shutdown detection.
ssh_cleanup_multiplex

# --- step 5: wait for bootloader -------------------------------------------
# Two-phase wait to avoid ARP false positives (Linux responds to ARP for
# BOOT_IP via ARP flux while still shutting down).

IFACE="$(ip route get "$BOOT_IP" 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)"
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
# Forward the kernel selection to flash_kernel.sh. An explicit --image wins over
# BOARD/KERNEL (flash_kernel.sh resolves the image from the exported BOARD/KERNEL
# when no --image is given). Only the kernel script understands --image; warn
# (don't fail) for the others. flash_bootloader.sh resolves its per-board
# boot.bin from the exported BOARD the same way.
if [ "$COMPONENT" = "kernel" ]; then
    export BOARD KERNEL
elif [ "$COMPONENT" = "bootloader" ]; then
    export BOARD
fi
FLASH_ARGS=("$BOOT_IP")
if [ -n "$IMAGE_OVERRIDE" ]; then
    if [ "$COMPONENT" = "kernel" ]; then
        FLASH_ARGS+=(--image "$IMAGE_OVERRIDE")
    else
        echo "Warning: --image is only honored for the kernel component; ignoring for ${COMPONENT}." >&2
    fi
fi
./"$FLASH_SCRIPT" "${FLASH_ARGS[@]}"
