#!/bin/bash
#
# backup_mtd_via_ssh.sh — Backup one or all MTD partitions via SSH + dd
#
# Usage:
#   ./backup_mtd_via_ssh.sh all   <gateway_ip> [port]
#   ./backup_mtd_via_ssh.sh mtd2  <gateway_ip> [port]
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

if [ "$PART" = "all" ]; then
    MTDS=(mtd0 mtd1 mtd2 mtd3 mtd4)
else
    MTDS=("$PART")
fi

echo "[*] Starting MTD backup over SSH (${GATEWAY_IP}:${SSH_PORT})..."

for mtd in "${MTDS[@]}"; do
    echo "  - Dumping ${mtd}..."

    # cat streams the raw character device to stdout — no block size issues
    ssh ${SSH_OPTS} ${SSH_USER}@${GATEWAY_IP} \
        "cat /dev/${mtd}" > "${mtd}.bin" 2>"${mtd}.bin.log"
done

if [ "$PART" = "all" ]; then
    echo "[*] Creating fullmtd.bin..."
    cat mtd0.bin mtd1.bin mtd2.bin mtd3.bin mtd4.bin > fullmtd.bin
fi

echo ""

declare -A EXPECTED_SIZES
EXPECTED_SIZES["mtd0"]=131072
EXPECTED_SIZES["mtd1"]=1966080
EXPECTED_SIZES["mtd2"]=2097152
EXPECTED_SIZES["mtd3"]=131072
EXPECTED_SIZES["mtd4"]=12451840

for mtd in "${MTDS[@]}"; do
    if [ -f "${mtd}.bin" ]; then
        size=$(stat -c %s "${mtd}.bin")
        expected=${EXPECTED_SIZES[$mtd]}
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
