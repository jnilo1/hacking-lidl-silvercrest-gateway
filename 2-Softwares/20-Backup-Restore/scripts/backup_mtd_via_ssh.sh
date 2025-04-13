#!/bin/bash
#
# backup_mtd_via_ssh.sh (Production version with selective backup)
#
# Usage:
#   ./backup_mtd_via_ssh.sh all <gateway_ip>
#   ./backup_mtd_via_ssh.sh mtd2 <gateway_ip>
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

echo "[*] Starting MTD backup over SSH..."

for mtd in "${MTDS[@]}"; do
    echo "  - Dumping and retrieving $mtd..."
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
                echo "Backing up partition \$mtd to /tmp/\$mtd.bin..." >&2
                dd if=/dev/\$mtd of=/tmp/\$mtd.bin bs=1024k
                echo "Remounting \$mtd to \$MOUNT_POINT" >&2
                mount -t jffs2 /dev/mtdblock\${mtd:3} \$MOUNT_POINT
                echo "Restarting serialgateway..." >&2
                /tuya/serialgateway &
            else
                echo "\$mtd is not mounted. Proceeding with backup..." >&2
                dd if=/dev/\$mtd of=/tmp/\$mtd.bin bs=1024k
            fi
            echo "Reading dump for \$mtd..." >&2
            cat /tmp/\$mtd.bin
            echo "Cleaning up temporary file /tmp/\$mtd.bin" >&2
            rm /tmp/\$mtd.bin" > "$mtd.bin" 2> "$mtd.bin.log"
    else
        ssh -p "$SSH_PORT" ${SSH_USER}@${GATEWAY_IP} "
            echo "Backing up partition $mtd to /tmp/$mtd.bin..." >&2
            dd if=/dev/$mtd of=/tmp/$mtd.bin bs=1024k
            echo "Reading dump for $mtd..." >&2
            cat /tmp/$mtd.bin
            echo "Cleaning up /tmp/$mtd.bin" >&2
            rm /tmp/$mtd.bin" > "$mtd.bin" 2> "$mtd.bin.log"
    fi
done

if [ "$PART" == "all" ]; then
    echo "[*] Creating fullmtd.bin..."
    cat mtd0.bin mtd1.bin mtd2.bin mtd3.bin mtd4.bin > fullmtd.bin
fi

for mtd in "${MTDS[@]}"; do
    if [ -f "$mtd.bin" ]; then
        size=$(stat -c %s "$mtd.bin")
    fi
done

if [ "$PART" == "all" ] && [ -f fullmtd.bin ]; then
    size=$(stat -c %s fullmtd.bin)
fi

echo

declare -A EXPECTED_SIZES
EXPECTED_SIZES["mtd0"]=131072
EXPECTED_SIZES["mtd1"]=1966080
EXPECTED_SIZES["mtd2"]=2097152
EXPECTED_SIZES["mtd3"]=131072
EXPECTED_SIZES["mtd4"]=12451840

for mtd in "${MTDS[@]}"; do
    if [ -f "$mtd.bin" ]; then
        size=$(stat -c %s "$mtd.bin")
        expected=${EXPECTED_SIZES[$mtd]}
        if [ "$size" -eq "$expected" ]; then
            echo "  - $mtd.bin: $size bytes [OK]"
        else
            echo "  - $mtd.bin: $size bytes [EXPECTED: $expected] [MISMATCH]"
        fi
    fi
done

if [ "$PART" == "all" ] && [ -f fullmtd.bin ]; then
    size=$(stat -c %s fullmtd.bin)
    if [ "$size" -eq 16777216 ]; then
        echo "  - fullmtd.bin: $size bytes [OK]"
    else
        echo "  - fullmtd.bin: $size bytes [EXPECTED: 16777216] [MISMATCH]"
    fi
fi

echo
echo "[✔] Backup completed successfully!"
