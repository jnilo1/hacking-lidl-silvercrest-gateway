#!/bin/bash
#
# restore_mtd_via_ssh.sh
#
# Description:
#   This script restores MTD partitions (mtd0 to mtd4) on the Lidl Silvercrest gateway via SSH.
#   It scans for matching .bin files (e.g., mtd2.bin) in the current directory.
#   For each match, it streams the binary to the gateway and flashes it using `dd`.
#
#   The script automatically handles mtd4 by checking if it's mounted, unmounting it before
#   flashing, and remounting it afterward to ensure filesystem integrity.
#
# Requirements:
#   - SSH access enabled on the gateway
#   - Corresponding mtdX.bin files must be present locally
#
# Usage:
#   chmod +x restore_mtd_via_ssh.sh
#   ./restore_mtd_via_ssh.sh
#
#

GATEWAY_IP="a.b.c.d"
SSH_PORT=22
SSH_USER="root"

SSH_OPTS=(-p "${SSH_PORT}" -oHostKeyAlgorithms=+ssh-rsa)

# List of MTD devices and matching local .bin files to send
MTDS=(mtd0 mtd1 mtd2 mtd3 mtd4)

echo "[*] Starting MTD restore over SSH..."

for mtd in "${MTDS[@]}"; do
    if [ -f "$mtd.bin" ]; then
        echo "  - Restoring $mtd from $mtd.bin..."
        
        if [ "$mtd" == "mtd4" ]; then
            # Special handling for mtd4 - unmount, flash, remount
            echo "    [*] Handling mounted partition mtd4..."
            ssh "${SSH_OPTS[@]}" "$SSH_USER@$GATEWAY_IP" "
                # Check if mtd4 is mounted and get mount point
                MOUNT_POINT=\$(grep $mtd /proc/mounts | awk '{print \$2}')
                if [ -n \"\$MOUNT_POINT\" ]; then
                    echo \"Unmounting $mtd from \$MOUNT_POINT\"
                    umount \$MOUNT_POINT || { echo \"Error unmounting $mtd\"; exit 1; }
                    # Receiving restore data from stdin
                    echo \"Flashing $mtd...\"
                    dd of=/dev/$mtd bs=1024k
                    RET=\$?
                    echo \"Remounting $mtd to \$MOUNT_POINT\"
                    mount -t jffs2 /dev/$mtd \$MOUNT_POINT
                    exit \$RET
                else
                    # Not mounted, proceed with normal restore
                    dd of=/dev/$mtd bs=1024k
                fi" < "$mtd.bin"
        else
            # Normal restore for other partitions
            cat "$mtd.bin" | ssh "${SSH_OPTS[@]}" "$SSH_USER@$GATEWAY_IP" "dd of=/dev/$mtd bs=1024k"
        fi
    else
        echo "  [!] Skipping $mtd: file $mtd.bin not found"
    fi
done

echo "[✔] Restore process completed!"
echo ""
echo "Note: If you flashed the boot or kernel partitions (mtd0/mtd1),"
echo "      you may need to reboot the device for changes to take effect."
