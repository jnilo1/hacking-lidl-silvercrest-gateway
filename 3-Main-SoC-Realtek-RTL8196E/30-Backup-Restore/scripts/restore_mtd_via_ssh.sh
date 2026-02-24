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

    if [ "$mtd" = "mtd4" ]; then
        # mtd4 (JFFS2 overlay) may be mounted — unmount before writing
        ssh ${SSH_OPTS} ${SSH_USER}@${GATEWAY_IP} bash <<REMOTE < "$binfile" 2>"${binfile}.log"
mtd=${mtd}
MOUNT_POINT=\$(grep mtdblock\${mtd:3} /proc/mounts | awk '{print \$2}')
if [ -n "\$MOUNT_POINT" ]; then
    echo "Detected mount point: \$MOUNT_POINT" >&2
    echo "Killing serialgateway..." >&2
    killall -q serialgateway || true
    echo "Unmounting \$mtd from \$MOUNT_POINT..." >&2
    umount \$MOUNT_POINT
fi
dd of=/dev/\$mtd bs=1024k 2>/dev/null
if [ -n "\$MOUNT_POINT" ]; then
    echo "Remounting \$mtd to \$MOUNT_POINT..." >&2
    mount -t jffs2 /dev/mtdblock\${mtd:3} \$MOUNT_POINT
    echo "Restarting serialgateway..." >&2
    /tuya/serialgateway &
fi
REMOTE
    else
        ssh ${SSH_OPTS} ${SSH_USER}@${GATEWAY_IP} \
            "dd of=/dev/${mtd} bs=1024k 2>/dev/null" < "$binfile" 2>"${binfile}.log"
    fi
done

echo ""
echo "[*] Restore completed."
