#!/bin/bash
#
# backup_partition_tftp.sh
#
# Description:
#   This script performs a backup of a single MTD partition (e.g., mtd2) from the Lidl Silvercrest gateway
#   using the Realtek bootloader and TFTP.
#
#   It maps the MTD name to the appropriate offset and size, sends an `FLR` command via UART (screen),
#   and retrieves the content via `tftp -g`.
#
# Requirements:
#   - Serial access to the Realtek bootloader (via /dev/ttyUSB0)
#   - TFTP client installed and reachable from the bootloader IP (usually 192.168.1.6)
#
# Usage:
#   chmod +x backup_partition_tftp.sh
#   ./backup_partition_tftp.sh mtd2
#
set -e

UART_DEV="/dev/ttyUSB0"
UART_BAUD=38400
GATEWAY_IP="192.168.1.6"
RAM_ADDR="80000000"

# Partition map
declare -A OFFSETS
declare -A SIZES

OFFSETS["mtd0"]="00000000"
SIZES["mtd0"]="00020000"

OFFSETS["mtd1"]="00020000"
SIZES["mtd1"]="001E0000"

OFFSETS["mtd2"]="00200000"
SIZES["mtd2"]="00200000"

OFFSETS["mtd3"]="00400000"
SIZES["mtd3"]="00020000"

OFFSETS["mtd4"]="00420000"
SIZES["mtd4"]="00BE0000"

if [ $# -ne 1 ]; then
    echo "Usage: $0 <mtdX>"
    exit 1
fi

PART="$1"

if [[ -z "${OFFSETS[$PART]}" ]]; then
    echo "[!] Unknown partition: $PART"
    exit 2
fi

OFFSET="${OFFSETS[$PART]}"
SIZE="${SIZES[$PART]}"
OUTFILE="$PART.bin"

echo "[*] Requesting dump of $PART (offset: 0x$OFFSET, size: 0x$SIZE) into RAM at $RAM_ADDR..."

# Send FLR command via UART using screen
{
    sleep 1
    echo ""
    sleep 1
    echo "IPCONFIG $GATEWAY_IP"
    sleep 1
    echo "FLR $RAM_ADDR $OFFSET $SIZE"
    sleep 1
} | screen -T dumb -L -Logfile uart_backup_log.txt "$UART_DEV" "$UART_BAUD"

echo "[*] Waiting 2 seconds before retrieving via TFTP..."
sleep 2

echo "[*] Downloading partition using TFTP..."
tftp -g -r "$OUTFILE" "$GATEWAY_IP"

echo "[✔] Backup complete: saved as $OUTFILE"
