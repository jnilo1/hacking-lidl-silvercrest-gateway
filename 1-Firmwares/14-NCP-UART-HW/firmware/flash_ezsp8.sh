#!/bin/bash
# linux bash script to update EZSP V8 silabs firmware - J Nilo April 2025
#
# To be used to flash a new firmware to an hacked Lidl/Silvercrest gateway using EZSP V8 & EmberZNet 6.7.8
#
# Download this script, sx xmodem utility and your firmware.gbl file in a working directory
# Make this script executable (chmod +x flash_ezsp8.sh) and run it
#
# Adjust ssh port and ssh options if needed
#
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
cp "$FIRMWARE_FILE" firmware.gbl
tar -czf ./firmware_package.tar.gz sx firmware.gbl

# Transfer files and execute commands in a single SSH session
# shellcheck disable=2086
ssh < ./firmware_package.tar.gz $SSH_OPTS "root@${GATEWAY_HOST}" "

# Transfer the file to /tmp and extract
cat > /tmp/firmware_package.tar.gz
cd /tmp
tar -xf firmware_package.tar.gz

# Make the sx file executable & kill serialgateway if running
chmod +x sx
killall -q serialgateway

# Configure serial port and send commands
stty -F /dev/ttyS1 115200 cs8 -cstopb -parenb -ixon crtscts raw
echo -en \"\x1a\xc0\x38\xbc\x7e\" > /dev/ttyS1
sleep 1
echo -n \".\"
echo -en \"\x00\x42\x21\xA8\x5C\x2C\xA0\x7E\" > /dev/ttyS1
sleep 1
echo -n \".\"
echo -en \"\x81\x60\x59\x7e\" > /dev/ttyS1
sleep 1
echo -n \".\"
echo -en \"\x7D\x31\x43\x21\x27\x55\x6E\x90\x7E\" > /dev/ttyS1
sleep 1
echo \".\"
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
