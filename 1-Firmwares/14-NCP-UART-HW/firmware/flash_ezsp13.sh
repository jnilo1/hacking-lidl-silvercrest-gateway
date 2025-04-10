#!/bin/bash
# flash_ezsp13.sh – Flash EZSP V13 firmware to Lidl/Silvercrest gateway
#
# Compatible with EZSP V13 (used with EmberZNet 7.x)
# Tested on EFR32MG1B232F256-based Lidl Silvercrest gateway
#
# Usage:
#   ./flash_ezsp13.sh <gateway_ip> <firmware.gbl>
#
# Requirements:
#   - sx (xmodem send utility) in current directory
#   - gateway reachable via SSH (default: root@<ip>, port 22)
#   - Zigbee2MQTT or ZHA must be stopped beforehand
#   - Make sure your firmware is a valid .gbl file for EZSP V13

SSH_PORT=22
SSH_OPTS=(-p "${SSH_PORT}" -oHostKeyAlgorithms=+ssh-rsa)

GATEWAY_HOST="$1"
FIRMWARE_FILE="$2"

# --- Input validation ---
if [ -z "$GATEWAY_HOST" ] || [ -z "$FIRMWARE_FILE" ]; then
    echo "Usage: $0 <gateway_host> <firmware_file>"
    echo "Example: $0 192.168.1.88 NCP_UHW_MG1B232_713.gbl"
    exit 1
fi

if [ ! -f "$FIRMWARE_FILE" ]; then
    echo "Error: Firmware file '$FIRMWARE_FILE' not found"
    exit 1
fi

if [ ! -f sx ]; then
    echo "Error: sx file (xmodem sender) not found in current directory"
    exit 1
fi

# --- Prepare archive ---
cp "$FIRMWARE_FILE" firmware.gbl
tar -czf firmware_package.tar.gz sx firmware.gbl

# --- Transfer and flash in one SSH session ---
cat firmware_package.tar.gz | ssh "${SSH_OPTS[@]}" root@"${GATEWAY_HOST}" '
cat > /tmp/firmware_package.tar.gz
cd /tmp
tar -xf firmware_package.tar.gz

chmod +x sx
killall -q serialgateway

# Serial initialization
stty -F /dev/ttyS1 115200 cs8 -cstopb -parenb -ixon crtscts raw

# EZSP V13 bootloader unlock sequence with pauses
echo -en "\x1A\xC0\x38\xBC\x7E" > /dev/ttyS1
sleep 1
echo -n "."
echo -en "\x00\x42\x21\xA8\x50\xED\x2C\x7E" > /dev/ttyS1
sleep 1
echo -n "."
echo -en "\x81\x60\x59\x7E" > /dev/ttyS1
sleep 1
echo -n "."
echo -en "\x7D\x31\x42\x21\xA9\x54\x2A\x7D\x38\xDC\x7A\x7E" > /dev/ttyS1
sleep 1
echo -n "."
echo -en "\x82\x50\x3A\x7E" > /dev/ttyS1
sleep 1
echo -n "."
echo -en "\x22\x43\x21\xA9\x7D\x33\x2A\x16\xB2\x59\x94\xE7\x9E\x7E" > /dev/ttyS1
sleep 1
echo -n "."
echo -en "\x83\x40\x1B\x7E" > /dev/ttyS1
sleep 1
echo -n "."
echo -en "\x33\x40\x21\xA9\xDB\x2A\x14\x8F\xC8\x7E" > /dev/ttyS1
sleep 1
echo -n "."

# Switch to XMODEM-compatible serial mode
stty -F /dev/ttyS1 115200 cs8 -cstopb -parenb -ixon -crtscts raw
echo -e "1" > /dev/ttyS1
sleep 1

# Firmware transfer
echo "Starting firmware transfer"
/tmp/sx /tmp/firmware.gbl < /dev/ttyS1 > /dev/ttyS1

# Cleanup and reboot
rm -f /tmp/sx /tmp/firmware.gbl /tmp/firmware_package.tar.gz
echo "Rebooting..."
reboot
'

# --- Local cleanup ---
rm -f firmware_package.tar.gz firmware.gbl

echo "Firmware update initiated. The gateway will reboot when complete."
exit 0

