#!/bin/bash
#
# restore_mtd_via_ssh.sh
#
# Description:
#   This script restores one or all MTD partitions (mtd0 to mtd4) on the Lidl Silvercrest gateway via SSH.
#   It uploads local mtdX.bin files to the device and writes them using dd.
#
# Usage:
#   ./restore_mtd_via_ssh.sh all <gateway_ip>     # restore all mtdX.bin files + fullmtd.bin optional
#   ./restore_mtd_via_ssh.sh mtd2 <gateway_ip>    # restore only mtd2.bin
#

set -e

PART="$1"
GATEWAY_IP="$2"
SSH_PORT=22
SSH_USER="root"

if [ -z "$PART" ] || [ -z "$GATEWAY_IP" ]; then
    echo "Usage: $0 <all|mtdX> <gateway_ip>"
    exit 1
fi

if [ "$PART" == "all" ]; then
    MTDS=(mtd0 mtd1 mtd2 mtd3 mtd4)
else
    MTDS=("$PART")
fi

echo "[*] Starting MTD restore over SSH..."

for mtd in "${MTDS[@]}"; do
    binfile="${mtd}.bin"
    if [ ! -f "$binfile" ]; then
        echo "[!] Skipping $mtd — file $binfile not found."
        continue
    fi

    echo "  - Uploading and restoring $mtd..."

    if [ "$mtd" == "mtd4" ]; then
        ssh -p "$SSH_PORT" ${SSH_USER}@${GATEWAY_IP} "
            mtd='$mtd'
            MOUNT_POINT=\$(grep mtdblock\${mtd:3} /proc/mounts | awk '{print \$2}')
            if [ -n "\$MOUNT_POINT" ]; then
                echo "Detected mount point: \$MOUNT_POINT" >&2
                echo "Killing serialgateway..." >&2
                killall -q serialgateway
                echo "Unmounting \$mtd from \$MOUNT_POINT" >&2
                umount \$MOUNT_POINT
            fi
            cat > /tmp/\$mtd.bin
            echo "Flashing \$mtd..." >&2
            dd if=/tmp/\$mtd.bin of=/dev/\$mtd bs=1024k
            rm /tmp/\$mtd.bin
            if [ -n "\$MOUNT_POINT" ]; then
                echo "Remounting \$mtd to \$MOUNT_POINT" >&2
                mount -t jffs2 /dev/mtdblock\${mtd:3} \$MOUNT_POINT
                echo "Restarting serialgateway..." >&2
                /tuya/serialgateway &
            fi
        " < "$binfile" 2> "$binfile.log"
    else
        ssh -p "$SSH_PORT" ${SSH_USER}@${GATEWAY_IP} "
            cat > /tmp/$mtd.bin
            echo "Flashing $mtd..." >&2
            dd if=/tmp/$mtd.bin of=/dev/$mtd bs=1024k
            rm /tmp/$mtd.bin
        " < "$binfile" 2> "$binfile.log"
    fi
done

echo "[✔] Restore completed."
