#!/bin/bash
#
# backup_partition_tftp.sh - Flash partition backup via Realtek bootloader and TFTP
#
# This script automates the backup process of flash memory partitions on devices
# with a Realtek bootloader, such as the Lidl Silvercrest gateway with GD25Q127C flash.
# It uses the bootloader's FLR (Flash Load to RAM) command to read the flash content 
# into RAM, and then downloads it via TFTP.
#
# Features:
# - Can backup a single partition or all partitions (0-4)
# - Verifies file size consistency
# - Creates a full flash image when all partitions are backed up
# - Configurable port, wait times, and output naming
#
# Usage: ./backup_partition_tftp.sh <partition_number|all> <gateway_ip> [OPTIONS]
#
# Author: J. Nilo with the help of claude.ai
# Version: 1.0.0 - April 2025
#

# Default configuration
UART_DEV="/dev/ttyUSB0"
UART_BAUD="38400"
LOCAL_IP=""
WAIT_TIME=2

# MTD partitions table (offset and size)
declare -A MTD_OFFSETS=( 
    ["0"]="00000000" ["1"]="00020000" ["2"]="00200000" ["3"]="00400000" ["4"]="00420000" 
)
declare -A MTD_SIZES=( 
    ["0"]="00020000" ["1"]="001E0000" ["2"]="00200000" ["3"]="00020000" ["4"]="00BE0000" 
)
declare -A RAM_ADDRS=(
    ["0"]="80000000" ["1"]="80000000" ["2"]="80000000" ["3"]="80000000" ["4"]="80000000"
)

# Expected sizes in bytes for verification
declare -A EXPECTED_SIZES=(
    ["mtd0"]=131072    # 0x00020000
    ["mtd1"]=1966080   # 0x001E0000
    ["mtd2"]=2097152   # 0x00200000
    ["mtd3"]=131072    # 0x00020000
    ["mtd4"]=12451840  # 0x00BE0000
)

# Help function
show_help() {
    echo "Flash Partition Backup via TFTP"
    echo
    echo "Usage: $0 <partition_number|all> <gateway_ip> [OPTIONS]"
    echo
    echo "Required arguments:"
    echo "  partition_number  MTD partition number (0-4) or 'all' for all partitions"
    echo "  gateway_ip        Gateway IP address"
    echo
    echo "Options:"
    echo "  -h, --help        Show this help message"
    echo "  -d, --device      Serial port (default: $UART_DEV)"
    echo "  -l, --local       Local IP address (optional)"
    echo "  -w, --wait        Wait time after FLR in seconds (default: $WAIT_TIME)"
    echo "  -o, --output      Output filename prefix (default: mtd)"
    echo
    echo "MTD Partitions table:"
    echo "  MTD0 (0x00000000, 0x00020000) - Bootloader + Config"
    echo "  MTD1 (0x00020000, 0x001E0000) - Kernel"
    echo "  MTD2 (0x00200000, 0x00200000) - Rootfs"
    echo "  MTD3 (0x00400000, 0x00020000) - Tuya Label"
    echo "  MTD4 (0x00420000, 0x00BE0000) - JFFS2 Overlay"
    echo
}

# Check if help is requested
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    show_help
    exit 0
fi

# Check required arguments
if [ $# -lt 2 ]; then
    echo "Error: Missing arguments."
    show_help
    exit 1
fi

# Get required arguments
PARTITION="$1"
GATEWAY_IP="$2"
shift 2

# Process additional options
OUTPUT_PREFIX="mtd"
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -d|--device)
            UART_DEV="$2"
            shift 2
            ;;
        -l|--local)
            LOCAL_IP="$2"
            shift 2
            ;;
        -w|--wait)
            WAIT_TIME="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_PREFIX="$2"
            shift 2
            ;;
        *)
            echo "Error: Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Define partitions to backup
if [ "$PARTITION" == "all" ]; then
    PARTITIONS=(0 1 2 3 4)
    echo "[*] Backing up all MTD partitions..."
else
    # Check partition validity
    if [[ ! "$PARTITION" =~ ^[0-4]$ ]]; then
        echo "Error: Invalid MTD partition. Must be between 0 and 4 or 'all'."
        exit 1
    fi
    PARTITIONS=("$PARTITION")
    echo "[*] Backing up MTD$PARTITION partition..."
fi

# Check if serial port exists
if [ ! -c "$UART_DEV" ]; then
    echo "Error: Serial port $UART_DEV does not exist."
    echo "Check connection or specify another port with -d."
    exit 1
fi

# Serial port configuration
stty -F "$UART_DEV" "$UART_BAUD" cs8 -cstopb -parenb -icanon -echo

# Function to send command to bootloader
send_command() {
    local cmd="$1"
    echo "Sending: $cmd"
    echo -e "$cmd\r" > "$UART_DEV"
    sleep 0.5
}

# Function to backup a partition
backup_partition() {
    local part="$1"
    local offset="${MTD_OFFSETS[$part]}"
    local size="${MTD_SIZES[$part]}"
    local ram_addr="${RAM_ADDRS[$part]}"
    local outfile="${OUTPUT_PREFIX}${part}.bin"
    
    echo "Configuration for MTD$part:"
    echo "  Gateway IP: $GATEWAY_IP"
    echo "  Partition: MTD$part (offset: 0x$offset, size: 0x$size)"
    echo "  RAM address: 0x$ram_addr"
    echo "  Output file: $outfile"
    echo ""
    
    echo "Starting backup procedure for MTD$part..."
    
    # Send commands to bootloader
    send_command ""
    if [ -n "$LOCAL_IP" ]; then
        send_command "IPCONFIG $GATEWAY_IP $LOCAL_IP"
    else
        send_command "IPCONFIG $GATEWAY_IP"
    fi
    
    echo "Reading flash to RAM..."
    send_command "FLR $ram_addr $offset $size"
    send_command "Y"
    
    # Wait for read completion
    echo "Waiting $WAIT_TIME seconds for read to complete..."
    sleep $WAIT_TIME
    
    # Download file via TFTP
    echo "Downloading via TFTP..."
    tftp -m binary "$GATEWAY_IP" -c get "$outfile"
    
    # Verify downloaded file size
    local expected_size_hex=$size
    local expected_size=$((16#$expected_size_hex))
    local expected_size_dec="${EXPECTED_SIZES[mtd$part]}"
    
    if [ -f "$outfile" ]; then
        local actual_size=$(stat -c %s "$outfile")
        if [ "$actual_size" -eq "$expected_size" ]; then
            echo "[✓] $outfile : $actual_size bytes [OK]"
            return 0
        else
            echo "[!] Incorrect size: $actual_size bytes, expected: $expected_size bytes [MISMATCH]"
            return 1
        fi
    else
        echo "[!] File $outfile not found after download."
        return 1
    fi
}

# Backup each requested partition
ERRORS=0
SUCCESSFUL_PARTITIONS=()

for part in "${PARTITIONS[@]}"; do
    echo "[*] Processing partition MTD$part..."
    if backup_partition "$part"; then
        SUCCESSFUL_PARTITIONS+=("$part")
    else
        ERRORS=$((ERRORS + 1))
    fi
    
    # Small pause between partitions
    if [ "$part" != "${PARTITIONS[-1]}" ]; then
        echo "Pausing 2 seconds before the next partition..."
        sleep 2
    fi
done

# Create a full image if all partitions were backed up
if [ "$PARTITION" == "all" ] && [ ${#SUCCESSFUL_PARTITIONS[@]} -eq 5 ]; then
    echo "[*] Creating full image (fullmtd.bin)..."
    cat "${OUTPUT_PREFIX}0.bin" "${OUTPUT_PREFIX}1.bin" "${OUTPUT_PREFIX}2.bin" "${OUTPUT_PREFIX}3.bin" "${OUTPUT_PREFIX}4.bin" > fullmtd.bin
    
    # Verify full image size
    FULLMTD_SIZE=$(stat -c %s fullmtd.bin)
    EXPECTED_FULLMTD_SIZE=16777216  # 16 MiB (16,777,216 bytes)
    
    if [ "$FULLMTD_SIZE" -eq "$EXPECTED_FULLMTD_SIZE" ]; then
        echo "[✓] fullmtd.bin : $FULLMTD_SIZE bytes [OK]"
    else
        echo "[!] Incorrect size for fullmtd.bin : $FULLMTD_SIZE bytes, expected: $EXPECTED_FULLMTD_SIZE bytes [MISMATCH]"
        ERRORS=$((ERRORS + 1))
    fi
fi

# Final summary
echo
if [ $ERRORS -eq 0 ]; then
    echo "[✓] Backup completed successfully!"
    exit 0
else
    echo "[!] Backup completed with $ERRORS error(s)."
    exit 1
fi
