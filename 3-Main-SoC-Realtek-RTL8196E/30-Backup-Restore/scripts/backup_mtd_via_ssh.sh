#!/bin/bash
#
# backup_mtd_via_ssh.sh — Backup MTD partitions via SSH + cat
#
# Supports the original Lidl/Tuya firmware only (5 partitions, port 2333).
# For custom firmware (4 partitions), use the bootloader FLR command instead.
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
# Port 2333: original Lidl/Tuya firmware (old Dropbear, needs legacy RSA key algorithm)
if [ "${SSH_PORT}" = "2333" ]; then
    SSH_OPTS="-p ${SSH_PORT} -o HostKeyAlgorithms=+ssh-rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
else
    SSH_OPTS="-p ${SSH_PORT} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
fi

if [ -z "$PART" ] || [ -z "$GATEWAY_IP" ]; then
    echo "Usage: $0 <all|mtdX> <gateway_ip> [port]"
    exit 1
fi

# Detect partition layout from /proc/mtd
echo "[*] Detecting partition layout on ${GATEWAY_IP}:${SSH_PORT}..."
GATEWAY_MTD=$(ssh ${SSH_OPTS} ${SSH_USER}@${GATEWAY_IP} "cat /proc/mtd" 2>/dev/null) || {
    echo "Error: cannot connect to ${GATEWAY_IP} on port ${SSH_PORT}." >&2
    if [ "${SSH_PORT}" = "2333" ]; then
        echo "Hint: custom firmware uses port 22 — retry with: $0 ${PART} ${GATEWAY_IP} 22" >&2
    else
        echo "Hint: original Lidl/Tuya firmware uses port 2333 — retry with: $0 ${PART} ${GATEWAY_IP} 2333" >&2
    fi
    exit 1
}

declare -A EXPECTED_SIZES
ALL_MTDS=()
while read -r dev size_hex _erase _name; do
    dev="${dev%:}"
    ALL_MTDS+=("$dev")
    EXPECTED_SIZES["$dev"]=$(printf '%d' "0x${size_hex}")
done < <(echo "$GATEWAY_MTD" | tail -n +2)

echo "    Found ${#ALL_MTDS[@]} partitions: ${ALL_MTDS[*]}"

# Only the original Lidl/Tuya firmware (5 partitions) is supported
if [ "${#ALL_MTDS[@]}" -ne 5 ]; then
    echo "" >&2
    echo "Error: ${#ALL_MTDS[@]}-partition layout detected — this is the custom firmware." >&2
    echo "SSH backup is not supported for this layout." >&2
    echo "" >&2
    echo "Use the bootloader FLR command to back up the full flash instead:" >&2
    echo "  1. Enter boot mode and interrupt the bootloader (ESC on serial console)" >&2
    echo "  2. Run: FLR 80500000 00000000 01000000" >&2
    echo "  3. Save the TFTP-transferred file as fullmtd.bin" >&2
    exit 1
fi

# Remove any stale mtdX.bin / fullmtd.bin from a previous (possibly different) backup
STALE=()
for f in mtd*.bin fullmtd.bin; do
    [ -f "$f" ] || continue
    # Keep only files that belong to the current layout
    base="${f%.bin}"
    if [ "$base" = "fullmtd" ]; then
        STALE+=("$f")
    else
        found=0
        for m in "${ALL_MTDS[@]}"; do [ "$m" = "$base" ] && found=1 && break; done
        [ "$found" -eq 0 ] && STALE+=("$f")
    fi
done
if [ ${#STALE[@]} -gt 0 ]; then
    echo "    Removing stale files from previous backup: ${STALE[*]}"
    rm -f "${STALE[@]}"
fi
rm -f fullmtd.bin

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
