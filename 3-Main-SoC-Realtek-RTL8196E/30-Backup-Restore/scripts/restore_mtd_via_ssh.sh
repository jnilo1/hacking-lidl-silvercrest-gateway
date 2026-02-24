#!/bin/bash
#
# restore_mtd_via_ssh.sh — Restore one or all MTD partitions via SSH + dd
#
# Usage:
#   ./restore_mtd_via_ssh.sh all   <gateway_ip> [port]
#   ./restore_mtd_via_ssh.sh mtd2  <gateway_ip> [port]
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

echo "[*] Starting MTD restore over SSH (${GATEWAY_IP}:${SSH_PORT})..."

for mtd in "${MTDS[@]}"; do
    binfile="${mtd}.bin"
    if [ ! -f "$binfile" ]; then
        echo "  [!] Skipping ${mtd} — file ${binfile} not found."
        continue
    fi

    echo "  - Restoring ${mtd}..."
    mtdnum="${mtd:3}"

    if [ "$mtd" = "mtd4" ]; then
        # mtd4 (JFFS2 overlay) may be mounted.
        # Cannot combine a heredoc script and binary stdin in a single SSH call,
        # so split into three calls: unmount / flash / remount.

        # Step 1: find mount point and unmount
        MOUNT_POINT=$(ssh ${SSH_OPTS} ${SSH_USER}@${GATEWAY_IP} \
            "grep mtdblock${mtdnum} /proc/mounts | awk '{print \$2}'" \
            2>>"${binfile}.log" || true)
        if [ -n "$MOUNT_POINT" ]; then
            ssh ${SSH_OPTS} ${SSH_USER}@${GATEWAY_IP} \
                "killall -q serialgateway 2>/dev/null || true; umount ${MOUNT_POINT}" \
                2>>"${binfile}.log"
        fi

        # Step 2: stream binary data directly to dd stdin
        ssh ${SSH_OPTS} ${SSH_USER}@${GATEWAY_IP} \
            "dd of=/dev/${mtd} bs=1024k 2>/dev/null" < "$binfile" 2>>"${binfile}.log"

        # Step 3: remount and restart service if it was mounted
        if [ -n "$MOUNT_POINT" ]; then
            ssh ${SSH_OPTS} ${SSH_USER}@${GATEWAY_IP} \
                "mount -t jffs2 /dev/mtdblock${mtdnum} ${MOUNT_POINT}; /tuya/serialgateway &" \
                2>>"${binfile}.log"
        fi
    else
        ssh ${SSH_OPTS} ${SSH_USER}@${GATEWAY_IP} \
            "dd of=/dev/${mtd} bs=1024k 2>/dev/null" < "$binfile" 2>"${binfile}.log"
    fi
done

echo ""
echo "[*] Restore completed."
