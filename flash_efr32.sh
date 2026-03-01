#!/bin/bash
# flash_efr32.sh — Flash firmware to the Silabs EFR32 Zigbee/Thread radio
#
# 1. Presents a menu to select the firmware type (NCP, RCP, OT-RCP, Router)
# 2. Ensures universal-silabs-flasher is available (installs in venv if needed)
# 3. SSHes into the gateway to restart serialgateway in flash mode (-f)
# 4. Flashes the selected firmware
# 5. Reboots the gateway (serialgateway restarts normally via init script)
#
# Note: OT-RCP (Spinel) firmware cannot enter the Gecko Bootloader via serial.
# If the EFR32 is running OT-RCP, you must flash a different firmware first
# (via SWD/JTAG or by power-cycling and catching the bootloader window).
#
# Usage: ./flash_efr32.sh [GATEWAY_IP]
#   GATEWAY_IP - Gateway IP address (default: 192.168.1.88)
#
# J. Nilo - February 2026

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GW_IP="${1:-192.168.1.88}"
GW_PORT=8888
VENV_DIR="${SCRIPT_DIR}/silabs-flasher"

SSH_OPTS="-o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new"
SSH="ssh $SSH_OPTS root@${GW_IP}"

FW_DIR="${SCRIPT_DIR}/2-Zigbee-Radio-Silabs-EFR32"

# --- Firmware table --------------------------------------------------------

FW_NCP="${FW_DIR}/24-NCP-UART-HW/firmware/ncp-uart-hw-7.5.1.gbl"
FW_RCP="${FW_DIR}/25-RCP-UART-HW/firmware/rcp-uart-802154.gbl"
FW_OT_RCP="${FW_DIR}/26-OT-RCP/firmware/ot-rcp.gbl"
FW_ROUTER="${FW_DIR}/27-Router/firmware/z3-router-7.5.1.gbl"

# --- Firmware selection menu -----------------------------------------------

echo "EFR32 Firmware Flasher"
echo ""
echo "  [1] NCP-UART-HW   — Zigbee NCP for zigbee2mqtt / ZHA  ($(basename "$FW_NCP"))"
echo "  [2] RCP-UART-HW   — Multi-PAN RCP for zigbee2mqtt     ($(basename "$FW_RCP"))"
echo "  [3] OT-RCP         — OpenThread RCP for otbr-agent      ($(basename "$FW_OT_RCP"))"
echo "  [4] Z3-Router      — Zigbee 3.0 standalone router       ($(basename "$FW_ROUTER"))"
echo ""
read -r -p "Firmware to flash [1]: " fw_choice
fw_choice="${fw_choice:-1}"

case "$fw_choice" in
    1) FIRMWARE="$FW_NCP" ;;
    2) FIRMWARE="$FW_RCP" ;;
    3) FIRMWARE="$FW_OT_RCP" ;;
    4) FIRMWARE="$FW_ROUTER" ;;
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
$SSH "killall serialgateway 2>/dev/null || true; serialgateway -f"
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
if ! "$FLASHER" --device "socket://${GW_IP}:${GW_PORT}" flash --firmware "$FIRMWARE"; then
    echo ""
    echo "Flash failed."
    echo ""
    echo "If the EFR32 is running OT-RCP (Spinel) firmware, it cannot enter the"
    echo "Gecko Bootloader via serial — this is a known Spinel protocol limitation."
    echo ""
    echo "Workaround: power-cycle the gateway, then re-run this script within a"
    echo "few seconds of boot (before the OT-RCP application fully starts)."
    echo "Or flash a different firmware (NCP, RCP) via SWD/JTAG debugger first."
    $SSH "reboot" 2>/dev/null || true
    exit 1
fi

# --- 4. Reboot -------------------------------------------------------------

echo ""
echo "Flash complete. Rebooting gateway..."
$SSH "reboot" 2>/dev/null || true

echo ""
echo "Done. Gateway rebooting — serialgateway will restart in normal mode (S60serialgateway)."
