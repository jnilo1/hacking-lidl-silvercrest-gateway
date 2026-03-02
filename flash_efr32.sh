#!/bin/bash
# flash_efr32.sh — Flash firmware to the Silabs EFR32 Zigbee/Thread radio
#
# 1. Presents a menu to select the firmware type (NCP, RCP, OT-RCP, Router)
# 2. Ensures universal-silabs-flasher is available (installs in venv if needed)
# 3. SSHes into the gateway to restart serialgateway in flash mode (-f)
# 4. Flashes the selected firmware
# 5. Reboots the gateway (serialgateway restarts normally via init script)
#
# Note: The Gecko Bootloader (stage 2) is rarely reflashed — only use [1] if
# you need to update the bootloader itself (e.g., after an SDK upgrade).
#
# Usage: ./flash_efr32.sh [GATEWAY_IP]
#   GATEWAY_IP - Gateway IP address (default: 192.168.1.88)
#
# J. Nilo - February 2026

set -euo pipefail

# Check that python3 and venv are available (needed for universal-silabs-flasher)
if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 not found." >&2
    echo "Install it with: sudo apt install python3" >&2
    exit 1
fi
if ! python3 -c "import venv" 2>/dev/null; then
    echo "Error: python3-venv not found." >&2
    echo "Install it with: sudo apt install python3-venv" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GW_IP="${1:-192.168.1.88}"
GW_PORT=8888
VENV_DIR="${SCRIPT_DIR}/silabs-flasher"

SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"
SSH="ssh $SSH_OPTS root@${GW_IP}"
SSH_RETRIES=3

FW_DIR="${SCRIPT_DIR}/2-Zigbee-Radio-Silabs-EFR32"

# --- Firmware table --------------------------------------------------------

FW_BTL="${FW_DIR}/23-Bootloader-UART-Xmodem/firmware/bootloader-uart-xmodem-2.4.2.gbl"
FW_NCP="${FW_DIR}/24-NCP-UART-HW/firmware/ncp-uart-hw-7.5.1.gbl"
FW_RCP="${FW_DIR}/25-RCP-UART-HW/firmware/rcp-uart-802154.gbl"
FW_OT_RCP="${FW_DIR}/26-OT-RCP/firmware/ot-rcp.gbl"
FW_ROUTER="${FW_DIR}/27-Router/firmware/z3-router-7.5.1.gbl"

# --- Firmware selection menu -----------------------------------------------

echo "EFR32 Firmware Flasher"
echo ""
echo "  [1] Bootloader    — Gecko Bootloader stage 2 (UART/Xmodem)   ($(basename "$FW_BTL"))"
echo "  [2] NCP-UART-HW   — Zigbee NCP for zigbee2mqtt / ZHA         ($(basename "$FW_NCP"))"
echo "  [3] RCP-UART-HW   — Multi-PAN RCP for zigbee2mqtt            ($(basename "$FW_RCP"))"
echo "  [4] OT-RCP        — OpenThread RCP for otbr-agent            ($(basename "$FW_OT_RCP"))"
echo "  [5] Z3-Router     — Zigbee 3.0 standalone router             ($(basename "$FW_ROUTER"))"
echo ""
read -r -p "Firmware to flash [2]: " fw_choice
fw_choice="${fw_choice:-2}"

case "$fw_choice" in
    1) FIRMWARE="$FW_BTL" ;;
    2) FIRMWARE="$FW_NCP" ;;
    3) FIRMWARE="$FW_RCP" ;;
    4) FIRMWARE="$FW_OT_RCP" ;;
    5) FIRMWARE="$FW_ROUTER" ;;
    *) echo "Invalid choice."; exit 1 ;;
esac

# --- Preflight -------------------------------------------------------------

if [ ! -f "$FIRMWARE" ]; then
    echo "Error: firmware not found: $FIRMWARE" >&2
    exit 1
fi

echo ""
echo "Firmware: $(basename "$FIRMWARE")"
echo "Gateway:  ${GW_IP}:${GW_PORT}"
echo ""

# --- 1. Check / install universal-silabs-flasher ---------------------------

if [ -x "${VENV_DIR}/bin/universal-silabs-flasher" ]; then
    FLASHER="${VENV_DIR}/bin/universal-silabs-flasher"
    echo "universal-silabs-flasher: venv (${VENV_DIR})"
elif command -v universal-silabs-flasher >/dev/null 2>&1; then
    FLASHER="universal-silabs-flasher"
    echo "universal-silabs-flasher: $(command -v universal-silabs-flasher)"
else
    echo "universal-silabs-flasher not found — installing in ${VENV_DIR}..."
    python3 -m venv "$VENV_DIR"
    "${VENV_DIR}/bin/pip" install --quiet universal-silabs-flasher
    FLASHER="${VENV_DIR}/bin/universal-silabs-flasher"
    echo "Installed."
fi
echo ""

# --- 2. SSH: restart serialgateway in flash mode (-f) ----------------------
# serialgateway -f disables hardware RTS/CTS.  The Gecko Bootloader uses
# XON/XOFF (software flow control) for Xmodem transfers.

echo "Connecting to ${GW_IP} — restarting serialgateway in flash mode..."
for i in $(seq 1 "$SSH_RETRIES"); do
    if $SSH "killall serialgateway 2>/dev/null || true; serialgateway -f"; then
        break
    fi
    if [ "$i" -eq "$SSH_RETRIES" ]; then
        echo "Error: cannot reach gateway after $SSH_RETRIES attempts." >&2
        exit 1
    fi
    echo "SSH timeout — retrying ($((i+1))/$SSH_RETRIES)..."
done
echo "serialgateway -f running on port ${GW_PORT}."
echo ""

# --- 3. Flash ---------------------------------------------------------------

read -r -p "Flash $(basename "$FIRMWARE") to ${GW_IP}? [y/N] " confirm
if [[ ! "$confirm" =~ ^[yY]$ ]]; then
    echo "Aborted."
    $SSH "reboot" 2>/dev/null || true
    exit 0
fi

echo ""
echo "Flashing..."

if [ "$FIRMWARE" = "$FW_BTL" ]; then
    # Bootloader flash: capture output to detect NoFirmwareError.
    # USF tries run_firmware() after upload, which fails because the
    # application slot is empty — the flash itself succeeded.
    FLASH_LOG=$(mktemp)
    trap 'rm -f "$FLASH_LOG"' EXIT
    "$FLASHER" --device "socket://${GW_IP}:${GW_PORT}" flash --firmware "$FIRMWARE" 2>&1 | tee "$FLASH_LOG" && FLASH_RC=0 || FLASH_RC=$?

    if [ $FLASH_RC -ne 0 ] && grep -q "NoFirmwareError" "$FLASH_LOG"; then
        echo ""
        echo "Bootloader flashed successfully."
        echo "The application slot is now empty — select a firmware to flash now:"
        echo ""
        echo "  [2] NCP-UART-HW   — Zigbee NCP for zigbee2mqtt / ZHA         ($(basename "$FW_NCP"))"
        echo "  [3] RCP-UART-HW   — Multi-PAN RCP for zigbee2mqtt            ($(basename "$FW_RCP"))"
        echo "  [4] OT-RCP        — OpenThread RCP for otbr-agent            ($(basename "$FW_OT_RCP"))"
        echo "  [5] Z3-Router     — Zigbee 3.0 standalone router             ($(basename "$FW_ROUTER"))"
        echo ""
        read -r -p "Firmware to flash [2]: " fw_choice2
        fw_choice2="${fw_choice2:-2}"
        case "$fw_choice2" in
            2) FIRMWARE="$FW_NCP" ;;
            3) FIRMWARE="$FW_RCP" ;;
            4) FIRMWARE="$FW_OT_RCP" ;;
            5) FIRMWARE="$FW_ROUTER" ;;
            *) echo "Invalid choice."; $SSH "reboot" 2>/dev/null || true; exit 1 ;;
        esac
        echo ""
        echo "Flashing $(basename "$FIRMWARE")..."
        "$FLASHER" --device "socket://${GW_IP}:${GW_PORT}" flash --firmware "$FIRMWARE"
    elif [ $FLASH_RC -ne 0 ]; then
        echo ""
        echo "Flash failed."
        echo ""
        echo "Check that serialgateway is running in flash mode and the gateway is"
        echo "reachable on ${GW_IP}:${GW_PORT}."
        $SSH "reboot" 2>/dev/null || true
        exit 1
    fi
else
    # Normal firmware flash: run USF directly so the progress bar works.
    if ! "$FLASHER" --device "socket://${GW_IP}:${GW_PORT}" flash --firmware "$FIRMWARE"; then
        echo ""
        echo "Flash failed."
        echo ""
        echo "Check that serialgateway is running in flash mode and the gateway is"
        echo "reachable on ${GW_IP}:${GW_PORT}."
        $SSH "reboot" 2>/dev/null || true
        exit 1
    fi
fi

# --- 4. Reboot -------------------------------------------------------------

echo ""
echo "Flash complete. Rebooting gateway..."
$SSH "reboot" 2>/dev/null || true

echo ""
echo "Done. Gateway rebooting — serialgateway will restart in normal mode (S60serialgateway)."
