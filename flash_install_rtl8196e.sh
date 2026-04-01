#!/bin/bash
# flash_install_rtl8196e.sh — Install custom firmware on Lidl Silvercrest Gateway
#
# Builds a fullflash.bin image (via build_fullflash.sh) and flashes it to the
# gateway via TFTP.
#
# Two modes of operation:
#   - Upgrade: pass LINUX_IP — the script connects via SSH, saves user config,
#     detects firmware type (custom vs Tuya via devmem), and triggers boothold
#     automatically (custom) or guides the user to serial (Tuya).
#   - First flash: no argument — the gateway must already be in bootloader mode
#     (<RealTek> prompt via serial ESC).
#
# Interactive vs non-interactive:
#   By default the script is interactive: it prompts for backup, flash
#   confirmation, and (on first flash) network/radio configuration.
#   Pass -y (or CONFIRM=y) for non-interactive mode — all prompts are skipped.
#   This enables unattended remote upgrades over SSH.
#   Note: if auto-flash fails and falls back to manual FLW, a terminal (tty)
#   is still required for serial console guidance.
#
# Works with any bootloader version:
#   - V2 custom bootloader (>= v2.0): auto-flashes on receiving a 16 MiB file
#   - Older bootloaders (Tuya, V1.2): guided LOADADDR + FLW via serial console
#
# Prerequisites:
#   - Ethernet cable between host and gateway
#   - tftp-hpa client installed (sudo apt install tftp-hpa)
#   - Serial console (3.3V UART, 38400 8N1, line wrap ON) — needed to enter
#     bootloader mode (first flash / Tuya) and for older bootloaders that
#     require manual flash commands (the script will guide you)
#
# Usage: ./flash_install_rtl8196e.sh [-y] [LINUX_IP] [--help]
#
# Arguments:
#   LINUX_IP        Gateway IP when running Linux (for upgrade with config save)
#                   Omit for first-time flash (gateway must be in bootloader mode)
#
# Options:
#   -y, --yes       Non-interactive mode: skip all confirmation prompts
#
# Environment variables:
#   BOOT_IP     - Gateway IP in bootloader (default: 192.168.1.6)
#   SSH_TIMEOUT - TCP probe timeout in seconds (default: 2)
#   NET_MODE    - "static" or "dhcp" (skip network prompt)
#   IPADDR      - Static IP address (default: 192.168.1.88)
#   NETMASK     - Netmask (default: 255.255.255.0)
#   GATEWAY     - Default gateway (default: 192.168.1.1)
#   RADIO_MODE  - "zigbee" or "thread" (skip radio prompt)
#   CONFIRM     - Set to "y" to skip confirmation prompts (same as -y)
#
# J. Nilo - March 2026

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINUX_IP=""
FW_VERSION=""
BOOT_IP="${BOOT_IP:-192.168.1.6}"
SSH_TIMEOUT="${SSH_TIMEOUT:-2}"

# --- argument parsing --------------------------------------------------------

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes) CONFIRM="y" ;;
        --help|-h)
            echo "Usage: $0 [-y] [LINUX_IP] [--help]"
            echo ""
            echo "Installs custom firmware on the Lidl Silvercrest Gateway."
            echo ""
            echo "Arguments:"
            echo "  LINUX_IP       Gateway IP when running Linux (upgrade with config save)"
            echo "                 Omit for first-time flash (gateway must be in bootloader)"
            echo ""
            echo "Options:"
            echo "  -y, --yes      Non-interactive mode (skip all prompts)"
            echo ""
            echo "Environment: BOOT_IP, SSH_TIMEOUT, NET_MODE, RADIO_MODE, CONFIRM,"
            echo "  IPADDR, NETMASK, GATEWAY"
            exit 0
            ;;
        --*) echo "Unknown option: $1. Use --help for usage."; exit 1 ;;
        *)
            if [ -n "$LINUX_IP" ]; then
                echo "Error: unexpected argument '$1' (LINUX_IP already set to '$LINUX_IP')." >&2
                exit 1
            fi
            LINUX_IP="$1"
            ;;
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


# --- detect gateway state (early — fail fast before building) ----------------
# If LINUX_IP is provided, probe SSH to determine firmware type and save config.
# Otherwise, check if bootloader is already reachable at BOOT_IP.

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

# Detect gateway state based on whether LINUX_IP was provided
LINUX_RUNNING=""
if [ -n "$LINUX_IP" ]; then
    echo "Probing SSH on ${LINUX_IP}..."
    if timeout "$SSH_TIMEOUT" bash -c "echo >/dev/tcp/$LINUX_IP/22" 2>/dev/null; then
        LINUX_RUNNING="${LINUX_IP}:22"
    elif timeout "$SSH_TIMEOUT" bash -c "echo >/dev/tcp/$LINUX_IP/2333" 2>/dev/null; then
        LINUX_RUNNING="${LINUX_IP}:2333"
    else
        echo "Error: cannot reach gateway at ${LINUX_IP} (no SSH on port 22 or 2333)." >&2
        echo "Check the Ethernet cable, or if the gateway is already in bootloader mode" >&2
        echo "re-run without argument:  $0" >&2
        exit 1
    fi
fi

if [ -n "$LINUX_RUNNING" ]; then
    fw_host="${LINUX_RUNNING%%:*}"
    fw_port="${LINUX_RUNNING##*:}"
    echo "Linux detected at ${fw_host}:${fw_port}."

    if [ "$fw_port" = "2333" ]; then
        # Port 2333 is exclusively Tuya/Lidl — no SSH needed
        fw_type="tuya"
    else
        # Port 22 — could be custom or Tuya; SSH in to check
        SSH_SOCK="/tmp/flash_install_ssh_$$"
        FI_SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o ControlMaster=auto -o ControlPath=$SSH_SOCK -o ControlPersist=10 -p $fw_port"

        # Verify SSH access before proceeding
        # shellcheck disable=SC2086
        if ! ssh $FI_SSH_OPTS "root@${fw_host}" "true" 2>/dev/null; then
            echo "Error: SSH authentication failed." >&2
            exit 1
        fi

        # Detect firmware type: devmem present = custom firmware (can boothold)
        # devmem absent = Tuya firmware (even if SSH port was changed to 22)
        # shellcheck disable=SC2086
        if ssh $FI_SSH_OPTS "root@${fw_host}" "command -v devmem" >/dev/null 2>&1; then
            fw_type="custom"
        else
            fw_type="tuya"
        fi
    fi
    echo "Firmware type: ${fw_type}"

    # Read firmware version early (used for display and auto-flash detection)
    if [ "$fw_type" = "custom" ]; then
        # shellcheck disable=SC2086
        fw_ver_line=$(ssh $FI_SSH_OPTS "root@${fw_host}" "head -1 /userdata/etc/version" 2>/dev/null || true)
        if [[ "$fw_ver_line" =~ v([0-9]+\.[0-9]+\.[0-9]+) ]]; then
            FW_VERSION="${BASH_REMATCH[1]}"
            echo "Firmware version: v${FW_VERSION}"
        fi
    fi

    # --- propose backup (while Linux is still running) -----------------------
    # Skipped in non-interactive mode (-y / CONFIRM=y)
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
        # Save user config before reboot (will be injected into userdata)
        # Only user-configurable files — not init scripts or system files
        # Work on a temporary copy of the skeleton — never modify the original
        USERDATA_SKEL="${SCRIPT_DIR}/3-Main-SoC-Realtek-RTL8196E/34-Userdata/skeleton"
        SKEL_WORK=$(mktemp -d)
        cp -a "$USERDATA_SKEL/." "$SKEL_WORK/"
        trap 'rm -rf "$SKEL_WORK"' EXIT
        export SKELETON_DIR="$SKEL_WORK"

        SAVE_TAR=$(mktemp)
        SAVE_FILES="etc/eth0.conf etc/mac_address etc/radio.conf etc/leds.conf etc/passwd etc/TZ etc/hostname etc/dropbear ssh thread"
        # shellcheck disable=SC2086
        ssh $FI_SSH_OPTS "root@${fw_host}" \
            "tar cf - -C /userdata $SAVE_FILES 2>/dev/null" > "$SAVE_TAR" 2>/dev/null || true
        if [ -s "$SAVE_TAR" ]; then
            tar xf "$SAVE_TAR" -C "$SKEL_WORK" 2>/dev/null || true
            echo "Gateway config saved."
            export NET_MODE="skip"
            export RADIO_MODE="skip"
        fi
        rm -f "$SAVE_TAR"

        echo "Sending boothold + reboot..."
        # shellcheck disable=SC2086
        ssh $FI_SSH_OPTS "root@${fw_host}" "boothold && reboot" 2>/dev/null || true
        # Close ControlMaster socket — gateway is rebooting
        ssh -O exit -o ControlPath="$SSH_SOCK" "root@${fw_host}" 2>/dev/null || true
    else
        echo ""
        echo "Tuya firmware detected. Cannot boothold automatically."
        echo "To enter bootloader mode:"
        echo "  - Connect serial console (3.3V UART, 38400 8N1, line wrap ON)"
        echo "  - Power cycle the gateway"
        echo "  - Press ESC repeatedly during boot to get the <RealTek> prompt"
        echo "  - Then re-run:  $0"
        echo ""
        exit 1
    fi

    # --- wait for bootloader after boothold + reboot -------------------------
    # Two-phase wait to avoid ARP false positives (Linux responds to ARP for
    # BOOT_IP via ARP flux while still shutting down).

    # Phase 1: wait for SSH to go down (Linux is shutting down)
    echo "Waiting for shutdown..."
    tries=0
    while [ $tries -lt 15 ]; do
        if ! timeout 1 bash -c "echo >/dev/tcp/$fw_host/$fw_port" 2>/dev/null; then
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
    done

    if [ $tries -ge 30 ]; then
        echo "Error: bootloader not detected after boothold." >&2
        exit 1
    fi
else
    # No LINUX_IP given — check if bootloader is reachable via ARP
    ip neigh del "$BOOT_IP" dev "$IFACE" 2>/dev/null || true
    bash -c "echo -n X >/dev/udp/$BOOT_IP/69" 2>/dev/null || true
    sleep 0.3

    nei="$(ip neigh show "$BOOT_IP" dev "$IFACE" 2>/dev/null || true)"
    if ! echo "$nei" | grep -Eqi 'lladdr [0-9a-f]{2}(:[0-9a-f]{2}){5}'; then
        echo "Gateway not detected at ${BOOT_IP}."
        echo ""
        echo "For first-time flash:"
        echo "  - Connect serial console (3.3V UART, 38400 8N1, line wrap ON)"
        echo "  - Power cycle the gateway"
        echo "  - Press ESC repeatedly during boot to get the <RealTek> prompt"
        echo "  - Then re-run:  $0"
        echo ""
        echo "For upgrade (with config save):"
        echo "  - Run:  $0 <GATEWAY_IP>   (e.g. $0 192.168.1.88)"
        echo ""
        exit 1
    fi

    # ARP resolved — but is it really bootloader? Probe TFTP to confirm.
    # Use PUT (not GET): bootloader ACKs a WRQ immediately, but silently drops
    # RRQ (prints error on serial only, no UDP response → tftp-hpa hangs).
    # timeout returns 124 when no TFTP server responds; 0 when bootloader ACKs.
    probe_file=$(mktemp)
    echo -n X > "$probe_file"
    probe_rc=0
    timeout 3 tftp -m binary "$BOOT_IP" -c put "$probe_file" >/dev/null 2>&1 || probe_rc=$?
    rm -f "$probe_file"
    if [ $probe_rc -eq 124 ]; then
        echo "Device at ${BOOT_IP} is not in bootloader mode (no TFTP server)."
        echo "If the gateway is running Linux, run:  $0 <GATEWAY_IP>"
        exit 1
    fi

    # ARP resolved + TFTP responding = bootloader.
    echo ""
    echo "Bootloader detected. No config files/variables will be imported"
    echo "You will be prompted for network and radio settings."
    if [ "${CONFIRM:-}" != "y" ]; then
        read -r -p "Proceed? [y/N] " r
        if [[ ! "$r" =~ ^[yY]$ ]]; then
            echo "Aborted."
            exit 0
        fi
    fi
fi

# Detect bootloader type:
#   - Custom firmware always has V2.3 bootloader — no need to ping.
#   - First flash (no LINUX_IP): probe with ping (V2 responds, older don't).
if [ "${fw_type:-}" = "custom" ]; then
    BOOTLOADER_TYPE="v2"
else
    BOOTLOADER_TYPE="old"
    if ping -c 1 -W 2 "$BOOT_IP" >/dev/null 2>&1; then
        BOOTLOADER_TYPE="v2"
    fi
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
# Called with -q (quiet): only config → lines, errors, and a summary are shown.
# Run build_fullflash.sh without -q for full verbose output.

"${SCRIPT_DIR}/build_fullflash.sh" -q

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
# Last chance to abort. Skipped in non-interactive mode (-y / CONFIRM=y).

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
    echo "Upload OK."

    # Auto-flash with UDP notification:
    # - Upgrade path (SSH): FW_VERSION >= 2.0 confirms bootloader has auto-flash
    # - First flash (no SSH): V2 bootloader → try auto-flash (3 min timeout,
    #   falls back to manual FLW if bootloader is a pre-v2.0.0 V2.3 without it)
    has_autoflash=false
    if [ -n "$FW_VERSION" ]; then
        fw_major="${FW_VERSION%%.*}"
        if [ "$fw_major" -ge 2 ] 2>/dev/null; then
            has_autoflash=true
        fi
    elif [ "$BOOTLOADER_TYPE" = "v2" ]; then
        has_autoflash=true
    fi

    result=""
    if [ "$has_autoflash" = true ]; then
        echo "Waiting for auto-flash (up to 3 minutes)..."

        # Wait for UDP notification (OK or FAIL) on port 9999
        # Flash takes ~2 minutes — timeout must cover the full write cycle.
        if command -v nc >/dev/null 2>&1; then
            notify_file=$(mktemp)
            (timeout 180 nc -u -l -p 9999 > "$notify_file" 2>/dev/null) &
            nc_pid=$!

            while kill -0 "$nc_pid" 2>/dev/null; do
                [ -s "$notify_file" ] && { kill "$nc_pid" 2>/dev/null; break; }
                sleep 0.5
            done
            wait "$nc_pid" 2>/dev/null || true
            result=$(tr -d '\0' < "$notify_file" 2>/dev/null || true)
            rm -f "$notify_file"
        fi
    else
        echo "Firmware < v2.0.0 (or unknown) — no auto-flash support."
    fi

    if [ "$result" = "OK" ]; then
        echo ""
        echo "========================================="
        echo "  INSTALLATION COMPLETE"
        echo "========================================="
        echo ""
        echo "Flash write succeeded. The gateway will reboot automatically."
        echo "SSH: root@${LINUX_IP:-${IPADDR:-192.168.1.88}}:22 (no password) in ~30 seconds."
    else
        # Auto-flash failed or no notification — fallback to manual FLW.
        # This path requires an interactive terminal for serial console guidance.
        if [ "$result" = "FAIL" ]; then
            echo "Auto-flash reported FAIL. Falling back to manual flash."
        else
            echo "No auto-flash notification. Falling back to manual flash."
        fi
        if [ ! -t 0 ]; then
            echo "Error: manual flash requires an interactive terminal (serial console guidance)." >&2
            exit 1
        fi
        echo ""
        echo "The image is in the gateway's RAM. On the serial console (38400 8N1, line wrap ON), type:"
        echo ""
        echo "    FLW 0 80500000 01000000"
        echo ""
        echo "Answer (Y)es when prompted on the serial console and..."
        echo "... wait 2mn until you see the <RealTek> prompt."
        echo ""
        echo "Then, on the serial console, type:"
        echo ""
        echo "    J BFC00000"
        echo ""
        echo "Or do a hard reset / power cycle."
        echo ""
        echo "========================================="
        echo "  INSTALLATION COMPLETE"
        echo "========================================="
        echo ""
        echo "SSH: root@${LINUX_IP:-${IPADDR:-192.168.1.88}}:22 (no password) in ~30 seconds."
    fi

else
    # --- Older bootloader: LOADADDR + upload + FLW ----------------------------
    # No auto-flash on older bootloaders — requires serial console interaction.
    # Abort early if stdin is not a terminal (pipe, cron, ssh without tty).
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
    echo "On the serial console (38400 8N1, line wrap ON), type:"
    echo ""
    echo "    FLW 0 80500000 01000000"
    echo ""
    echo "Answer (Y)es when prompted on the serial console and..."
    echo "... wait 2mn until you see the <RealTek> prompt."
    echo ""
    echo "Then, on the serial console, type:"
    echo ""
    echo "    J BFC00000"
    echo ""
    echo "Or do a hard reset / power cycle."
    echo ""
    echo "========================================="
    echo "  INSTALLATION COMPLETE"
    echo "========================================="
    echo ""
    echo "SSH: root@${LINUX_IP:-${IPADDR:-192.168.1.88}}:22 (no password) in ~30 seconds."
fi

# --- Restore skeleton if we injected gateway config -------------------------
# --- EFR32 radio firmware info -----------------------------------------------
if [ "${CONFIRM:-}" != "y" ] && [ -t 0 ]; then
    RADIO="${NET_MODE:+${RADIO_MODE}}"
    # Determine radio mode from radio.conf if not set by env
    if [ -z "$RADIO" ]; then
        RADIO_CONF="${SKEL_WORK:-${SCRIPT_DIR}/3-Main-SoC-Realtek-RTL8196E/34-Userdata/skeleton}/etc/radio.conf"
        if [ -f "$RADIO_CONF" ] && grep -q '^MODE=otbr' "$RADIO_CONF" 2>/dev/null; then
            RADIO="thread"
        else
            RADIO="zigbee"
        fi
    fi

    echo ""
    echo "Make sure the EFR32 radio firmware matches your configuration."
    echo "Compatible firmware(s):"
    echo ""
    if [ "$RADIO" = "thread" ]; then
        echo "  ot-rcp.gbl             — OpenThread RCP (required for OTBR)"
    else
        echo "  ncp-uart-hw-7.5.1.gbl  — Zigbee NCP for serialgateway + Z2M"
        echo "  rcp-uart-802154.gbl    — Zigbee RCP for cpcd + zigbeed (Docker)"
        echo "  z3-router-7.5.1.gbl    — Zigbee 3.0 Router (standalone, no coordinator)"
    fi
    echo ""
    echo "Flash with:  ./flash_efr32.sh ${LINUX_IP:-${IPADDR:-192.168.1.88}}"
fi
