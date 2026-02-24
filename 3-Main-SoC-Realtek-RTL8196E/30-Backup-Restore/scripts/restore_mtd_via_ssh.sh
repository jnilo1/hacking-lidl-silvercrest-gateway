#!/bin/bash
#
# restore_mtd_via_ssh.sh — Restore one or all MTD partitions via SSH + dd
#
# Automatically detects the gateway firmware layout (original Lidl/Tuya
# with 5 partitions, or custom firmware with 4 partitions) by reading
# /proc/mtd on the gateway. The last partition (JFFS2) is handled with
# unmount/remount around the flash write.
#
# Usage:
#   ./restore_mtd_via_ssh.sh all   <gateway_ip> [port]
#   ./restore_mtd_via_ssh.sh mtdX  <gateway_ip> [port]
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

ALL_MTDS=()
while read -r dev _size _erase _name; do
    ALL_MTDS+=("${dev%:}")
done < <(echo "$GATEWAY_MTD" | tail -n +2)

# The last partition is always the JFFS2 overlay (needs unmount/remount)
JFFS2_MTD="${ALL_MTDS[-1]}"
JFFS2_NUM="${JFFS2_MTD:3}"

echo "    Found ${#ALL_MTDS[@]} partitions: ${ALL_MTDS[*]}"
echo "    JFFS2 partition: ${JFFS2_MTD}"

if [ "$PART" = "all" ]; then
    MTDS=("${ALL_MTDS[@]}")
    echo ""
    echo "    Note: each partition requires a separate SSH connection."
    echo "    ${JFFS2_MTD} (JFFS2): up to 4 prompts (unmount/flash/remount)."
    echo "    ${JFFS2_MTD} transfer will take 1-2 minutes — do not interrupt."
else
    MTDS=("$PART")
fi

echo "[*] Starting restore over SSH..."

for mtd in "${MTDS[@]}"; do
    binfile="${mtd}.bin"
    if [ ! -f "$binfile" ]; then
        echo "  [!] Skipping ${mtd} — file ${binfile} not found."
        continue
    fi

    echo "  - Restoring ${mtd}..."
    mtdnum="${mtd:3}"

    if [ "$mtd" = "$JFFS2_MTD" ]; then
        # JFFS2 partition may be mounted.
        # Split into separate SSH calls: unmount / flash / remount.

        # Step 1: find mount point and unmount (failure is non-fatal)
        MOUNT_POINT=$(ssh ${SSH_OPTS} ${SSH_USER}@${GATEWAY_IP} \
            "grep mtdblock${mtdnum} /proc/mounts | awk '{print \$2}'" \
            2>"${binfile}.log" || true)
        if [ -n "$MOUNT_POINT" ]; then
            ssh ${SSH_OPTS} ${SSH_USER}@${GATEWAY_IP} \
                "killall -q serialgateway 2>/dev/null || true; umount ${MOUNT_POINT} || true" \
                2>>"${binfile}.log"
        fi

        # Step 2: stream binary data directly to dd stdin
        ssh ${SSH_OPTS} ${SSH_USER}@${GATEWAY_IP} \
            "dd of=/dev/${mtd} bs=1024k 2>/dev/null" < "$binfile" 2>>"${binfile}.log"

        # Step 3: remount if it was previously mounted
        if [ -n "$MOUNT_POINT" ]; then
            ssh ${SSH_OPTS} ${SSH_USER}@${GATEWAY_IP} \
                "mount -t jffs2 /dev/mtdblock${mtdnum} ${MOUNT_POINT}; /tuya/serialgateway &" \
                2>>"${binfile}.log" || true
        fi
    else
        ssh ${SSH_OPTS} ${SSH_USER}@${GATEWAY_IP} \
            "dd of=/dev/${mtd} bs=1024k 2>/dev/null" < "$binfile" 2>"${binfile}.log"
    fi
done

echo ""
echo "[*] Restore completed."
