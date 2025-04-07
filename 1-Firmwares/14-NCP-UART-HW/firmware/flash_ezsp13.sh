#!/bin/bash
# script to update EZSP V13 silabs firmware - J Nilo April 2025
# Updated version:
# - one ssh version instead of 3
# - ssh parameters taking care of recent ssh constraints and adjustable through SSH_OPTS
# - sleep statements introduced to limit timeouts
# - only two input parameters: gateway ip address and firmware.gbl filename
#
# - download this script, sx xmodem send utility and firmware.gbl file in a working dir and execute flash_ezsp13.sh

# Adjust ssh port and ssh options if needed
SSH_PORT=22
SSH_OPTS="-p${SSH_PORT} -oHostKeyAlgorithms=+ssh-rsa"

GATEWAY_HOST="$1"
FIRMWARE_FILE="$2"

# Validate input parameters
if [ -z "$GATEWAY_HOST" ] || [ -z "$FIRMWARE_FILE" ]; then
    echo "Usage: $0 <gateway_host> <firmware_file>"
    echo "Make sure Z2M or ZHA are disconnected"
    exit 1
fi

# Check if firmware file exists
if [ ! -f "$FIRMWARE_FILE" ]; then
    echo "Error: Firmware file '$FIRMWARE_FILE' not found"
    exit 1
fi

# Check if sx file exists
if [ ! -f sx ]; then
    echo "Error: sx file not found"
    exit 1
fi


# Create a temporary tarball containing the required files
cp $FIRMWARE_FILE firmware.gbl
tar -czf ./firmware_package.tar.gz sx firmware.gbl

# Transfer files and execute commands in a single SSH session
cat ./firmware_package.tar.gz | ssh $SSH_OPTS root@${GATEWAY_HOST} "

# Transfer the file to /tmp and extract
cat > /tmp/firmware_package.tar.gz
cd /tmp
tar -xf firmware_package.tar.gz

# Make the sx file executable & kill serialgateway if running
chmod +x sx
killall -q serialgateway

# Configure serial port and send commands
stty -F /dev/ttyS1 115200 cs8 -cstopb -parenb -ixon crtscts raw
echo -en "\x1a\xc0\x38\xbc\x7e" > /dev/ttyS1
sleep 1
echo -n "."
echo -en "\x00\x42\x21\xa8\x50\xed\x2c\x7e" > /dev/ttyS1
sleep 1
echo -n "."
echo -en "\x81\x60\x59\x7e" > /dev/ttyS1
sleep 1
echo -n "."
echo -en "\x7d\x31\x42\x21\xa9\x54\x2a\x7d\x38\xdc\x7a\x7e" > /dev/ttyS1
sleep 1
echo -n "."
echo -en "\x82\x50\x3a\x7e" > /dev/ttyS1
sleep 1
echo -n "."
echo -en "\x22\x43\x21\xa9\x7d\x33\x2a\x16\xb2\x59\x94\xe7\x9e\x7e" > /dev/ttyS1
sleep 1
echo -n "."
echo -en "\x83\x40\x1b\x7e" > /dev/ttyS1
sleep 1
echo -n "."
echo -en "\x33\x40\x21\xa9\xdb\x2a\x14\x8f\xc8\x7e" > /dev/ttyS1
sleep 1
echo -n "."
stty -F /dev/ttyS1 115200 cs8 -cstopb -parenb -ixon -crtscts raw
echo -e '1' > /dev/ttyS1
sleep 1
echo 'Starting firmware transfer'
/tmp/sx /tmp/firmware.gbl < /dev/ttyS1 > /dev/ttyS1
# Clean up and reboot
rm -rf /tmp/*
echo 'Rebooting...'
reboot
"
