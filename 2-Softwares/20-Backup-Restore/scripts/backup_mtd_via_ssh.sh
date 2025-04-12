#!/bin/bash
#
# backup_mtd_via_ssh.sh
#
# Description:
#   This script performs a full backup of the Lidl Silvercrest gateway's flash memory (GD25Q127C)
#   using SSH access to the embedded Linux system.
#
#   For each MTD partition (/dev/mtd0 to /dev/mtd4), it:
#     - creates a temporary dump on the device with dd
#     - transfers it back to the host over SSH
#     - deletes the temporary file
#   Finally, it concatenates all partitions into a single 'fullmtd.bin' image.
#
#   Note: mtd0-mtd3 are typically unmounted after being loaded into RAM, but mtd4 (JFFS2)
#   may need to be unmounted before backup to ensure data consistency.
#
# SSH access to the gateway: port 22 by default, change if needed
# Adjust GATEWAY_IP to your needs
#
# Usage:
#   chmod +x backup_mtd_via_ssh.sh
#   ./backup_mtd_via_ssh.sh
#

GATEWAY_IP="a.b.c.d"
SSH_PORT=22
SSH_USER="root"

MTDS=(mtd0 mtd1 mtd2 mtd3 mtd4)

echo "[*] Starting MTD backup over SSH (one-shot per partition)..."

for mtd in "${MTDS[@]}"; do
    echo "  - Dumping and retrieving $mtd..."
    if [ "$mtd" == "mtd4" ]; then
        # For mtd4 (JFFS2), unmount first if mounted, backup, then remount
        ssh -p "$SSH_PORT" ${SSH_USER}@${GATEWAY_IP} "
            # Check if mtd4 is mounted and get mount point
            MOUNT_POINT=\$(grep $mtd /proc/mounts | awk '{print \$2}')
            if [ -n \"\$MOUNT_POINT\" ]; then
                echo \"Unmounting $mtd from \$MOUNT_POINT\"
                umount \$MOUNT_POINT
                dd if=/dev/$mtd of=/tmp/$mtd.bin bs=1024k
                echo \"Remounting $mtd to \$MOUNT_POINT\"
                mount -t jffs2 /dev/$mtd \$MOUNT_POINT
            else
                # Not mounted, proceed with normal backup
                dd if=/dev/$mtd of=/tmp/$mtd.bin bs=1024k
            fi
            cat /tmp/$mtd.bin
            rm /tmp/$mtd.bin" > "$mtd.bin"
    else
        # For other partitions (normally already unmounted)
        ssh -p "$SSH_PORT" ${SSH_USER}@${GATEWAY_IP} "
            dd if=/dev/$mtd of=/tmp/$mtd.bin bs=1024k &&
            cat /tmp/$mtd.bin &&
            rm /tmp/$mtd.bin" > "$mtd.bin"
    fi
done

echo "[*] Creating fullmtd.bin..."
cat mtd0.bin mtd1.bin mtd2.bin mtd3.bin mtd4.bin > fullmtd.bin

echo "[✔] Backup completed successfully!"