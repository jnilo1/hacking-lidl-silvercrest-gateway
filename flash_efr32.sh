#!/bin/bash
# flash_efr32.sh — Flash NCP-UART-HW firmware to the Silabs EFR32 Zigbee radio
#
# 1. Ensures universal-silabs-flasher is available (installs in venv if needed)
# 2. SSHes into the gateway to restart serialgateway in flash mode (-f)
# 3. Probes the EFR32 to verify connectivity and identify current firmware
# 4. If probe succeeds, flashes ncp-uart-hw firmware
# 5. Reboots the gateway (serialgateway restarts normally via init script)
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
FIRMWARE="${SCRIPT_DIR}/2-Zigbee-Radio-Silabs-EFR32/24-NCP-UART-HW/firmware/ncp-uart-hw-7.5.1.gbl"

SSH_OPTS="-o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new"
SSH="ssh $SSH_OPTS root@${GW_IP}"

# --- Preflight -------------------------------------------------------------

if [ ! -f "$FIRMWARE" ]; then
    echo "Error: firmware not found: $FIRMWARE" >&2
    exit 1
fi

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
# The Gecko Bootloader uses software flow control (XON/XOFF).
# serialgateway -f disables hardware RTS/CTS, required for Xmodem to work.
#
# We keep the SSH session open for the duration of the flash: BusyBox ash
# kills background jobs when the session closes, so nohup is not reliable.
# The session (and serialgateway -f) are terminated after flash via SSH_SGWF_PID.

echo "Connecting to ${GW_IP} — restarting serialgateway in flash mode..."
# serialgateway -f daemonizes after printing its banner, so SSH exits normally.
$SSH "killall serialgateway 2>/dev/null || true; serialgateway -f"
echo "serialgateway -f running on port ${GW_PORT}."
echo ""

# --- 3. Probe ---------------------------------------------------------------

echo "Probing EFR32 firmware..."
if ! "$FLASHER" --device "socket://${GW_IP}:${GW_PORT}" probe; then
    echo "" >&2
    echo "Error: probe failed." >&2
    echo "Check: gateway reachable, serialgateway -f running, no other client on port ${GW_PORT}." >&2
    exit 1
fi
echo ""

# --- 4. Flash ---------------------------------------------------------------

read -r -p "Flash $(basename "$FIRMWARE") to ${GW_IP}? [y/N] " confirm
if [[ ! "$confirm" =~ ^[yY]$ ]]; then
    echo "Aborted."
    $SSH "reboot" 2>/dev/null || true
    exit 0
fi

echo ""
echo "Flashing..."
"$FLASHER" --device "socket://${GW_IP}:${GW_PORT}" flash --firmware "$FIRMWARE"

# --- 5. Reboot -------------------------------------------------------------

echo ""
echo "Flash complete. Rebooting gateway..."
$SSH "reboot" 2>/dev/null || true

echo ""
echo "Done. Gateway rebooting — serialgateway will restart in normal mode (S60serialgateway)."
