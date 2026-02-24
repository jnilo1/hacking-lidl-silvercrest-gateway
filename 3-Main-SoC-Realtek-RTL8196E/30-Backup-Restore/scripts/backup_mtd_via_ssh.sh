#!/bin/bash
#
# backup_mtd_via_ssh.sh — Backup one or all MTD partitions via SSH + dd
#
# Automatically detects the gateway firmware layout (original Lidl/Tuya
# with 5 partitions, or custom firmware with 4 partitions) by reading
# /proc/mtd on the gateway.
#
# Usage:
#   ./backup_mtd_via_ssh.sh all   <gateway_ip> [port]
#   ./backup_mtd_via_ssh.sh mtdX  <gateway_ip> [port]
#
#   port defaults to 2333 (Lidl/Tuya gateway default SSH port)
#
# J. Nilo - December 2025

set -e

PART="$1"
GATEWAY_IP="$2"
SSH_PORT="${3:-2333}"
SSH_USER="root"
SSH_OPTS="-p ${SSH_PORT} -o HostKeyAlgorithms=+ssh-rsa -o StrictHostKeyChecking=no"

if [ -z "$PART" ] || [ -z "$GATEWAY_IP" ]; then
    echo "Usage: $0 <all|mtdX> <gateway_ip> [port]"
    exit 1
fi

# Detect partition layout from /proc/mtd
echo "[*] Detecting partition layout on ${GATEWAY_IP}:${SSH_PORT}..."
GATEWAY_MTD=$(ssh ${SSH_OPTS} ${SSH_USER}@${GATEWAY_IP} "cat /proc/mtd" 2>/dev/null)

declare -A EXPECTED_SIZES
ALL_MTDS=()
while read -r dev size_hex _erase _name; do
    dev="${dev%:}"
    ALL_MTDS+=("$dev")
    EXPECTED_SIZES["$dev"]=$(printf '%d' "0x${size_hex}")
done < <(echo "$GATEWAY_MTD" | tail -n +2)

echo "    Found ${#ALL_MTDS[@]} partitions: ${ALL_MTDS[*]}"

if [ "$PART" = "all" ]; then
    MTDS=("${ALL_MTDS[@]}")
else
    MTDS=("$PART")
fi

echo "[*] Starting backup over SSH..."

for mtd in "${MTDS[@]}"; do
    echo "  - Dumping ${mtd}..."
    # cat streams the raw character device — no block size or mount issues
    ssh ${SSH_OPTS} ${SSH_USER}@${GATEWAY_IP} \
        "cat /dev/${mtd}" > "${mtd}.bin" 2>"${mtd}.bin.log"
done

if [ "$PART" = "all" ]; then
    echo "[*] Creating fullmtd.bin..."
    cat "${ALL_MTDS[@]/%/.bin}" > fullmtd.bin
fi

echo ""

for mtd in "${MTDS[@]}"; do
    if [ -f "${mtd}.bin" ]; then
        size=$(stat -c %s "${mtd}.bin")
        expected=${EXPECTED_SIZES[$mtd]:-0}
        if [ "$size" -eq "$expected" ]; then
            echo "  - ${mtd}.bin: ${size} bytes [OK]"
        else
            echo "  - ${mtd}.bin: ${size} bytes [EXPECTED: ${expected}] [MISMATCH]"
        fi
    fi
done

if [ "$PART" = "all" ] && [ -f fullmtd.bin ]; then
    size=$(stat -c %s fullmtd.bin)
    if [ "$size" -eq 16777216 ]; then
        echo "  - fullmtd.bin: ${size} bytes [OK]"
    else
        echo "  - fullmtd.bin: ${size} bytes [EXPECTED: 16777216] [MISMATCH]"
    fi
fi

echo ""
echo "[*] Backup completed."
