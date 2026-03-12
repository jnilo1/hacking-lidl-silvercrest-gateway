#!/bin/bash
# backup_gateway.sh — Unified backup script for Lidl Silvercrest Gateway
#
# Detects the gateway state (custom Linux, Tuya Linux, or bootloader) and
# chooses the best backup method automatically. Never modifies the system.
#
# Usage: ./backup_gateway.sh [--linux-ip IP] [--boot-ip IP] [--output DIR] [--help]
#
# J. Nilo - March 2026

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SPLIT_FLASH="${SCRIPT_DIR}/3-Main-SoC-Realtek-RTL8196E/30-Backup-Restore/split_flash.sh"

LINUX_IP="${LINUX_IP:-192.168.1.88}"
BOOT_IP="${BOOT_IP:-192.168.1.6}"
SSH_USER="${SSH_USER:-root}"
BACKUP_DIR="${BACKUP_DIR:-}"
FLASH_SIZE=$((16 * 1024 * 1024))  # 16 MiB

# --- argument parsing --------------------------------------------------------

while [ $# -gt 0 ]; do
    case "$1" in
        --linux-ip) shift; LINUX_IP="$1" ;;
        --boot-ip)  shift; BOOT_IP="$1" ;;
        --output)   shift; BACKUP_DIR="$1" ;;
        --help|-h)
            echo "Usage: $0 [--linux-ip IP] [--boot-ip IP] [--output DIR] [--help]"
            echo ""
            echo "Detects gateway state and backs up all flash partitions."
            echo ""
            echo "Options:"
            echo "  --linux-ip IP   Gateway IP under Linux (default: 192.168.1.88)"
            echo "  --boot-ip  IP   Gateway IP in bootloader (default: 192.168.1.6)"
            echo "  --output   DIR  Output directory (default: backups/YYYYMMDD-HHMM)"
            echo ""
            echo "Environment variables: LINUX_IP, BOOT_IP, BACKUP_DIR, SSH_USER"
            exit 0
            ;;
        *) echo "Unknown option: $1. Use --help for usage."; exit 1 ;;
    esac
    shift
done

if [ -z "$BACKUP_DIR" ]; then
    BACKUP_DIR="${SCRIPT_DIR}/backups/$(date '+%Y%m%d-%H%M')"
fi

# --- prerequisites -----------------------------------------------------------

# Check that tftp-hpa client is installed (the script uses its "-c" syntax)
check_tftp() {
    local tftp_usage
    tftp_usage="$(tftp --help 2>&1 || true)"
    if ! command -v tftp >/dev/null 2>&1 || ! echo "$tftp_usage" | grep -q '\-c'; then
        echo "Error: tftp-hpa client not found (need the -c flag)." >&2
        echo "Install it with: sudo apt install tftp-hpa" >&2
        exit 1
    fi
}

# Resolve the outgoing network interface to a given IP
resolve_iface() {
    local ip="$1"
    IFACE="$(ip route get "$ip" 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
    if [ -z "${IFACE:-}" ]; then
        echo "Error: cannot determine outgoing interface to ${ip}." >&2
        exit 1
    fi
    if ip route get "$ip" 2>/dev/null | grep -qE '\svia\s'; then
        echo "Error: ${ip} is reached via a gateway (routed). Must be same L2 segment." >&2
        exit 1
    fi
}

# --- detection helpers -------------------------------------------------------

# Check if bootloader is reachable (ARP resolves on BOOT_IP)
bootloader_reachable() {
    local iface
    iface="$(ip route get "$BOOT_IP" 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
    [ -z "$iface" ] && return 1

    ip neigh del "$BOOT_IP" dev "$iface" 2>/dev/null || true
    bash -c "echo -n X >/dev/udp/$BOOT_IP/69" 2>/dev/null || true
    sleep 0.3

    local nei
    nei="$(ip neigh show "$BOOT_IP" dev "$iface" 2>/dev/null || true)"
    echo "$nei" | grep -Eqi 'lladdr [0-9a-f]{2}(:[0-9a-f]{2}){5}'
}

# Check if SSH port is open
ssh_reachable() {
    local ip="$1" port="$2"
    timeout 2 bash -c "echo >/dev/tcp/$ip/$port" 2>/dev/null
}

# Detect gateway state: custom_linux, tuya_linux, bootloader, or fail
# SSH is tested first — it's a definitive TCP check, whereas ARP probes
# can give false positives from stale neighbour entries.
detect_state() {
    if ssh_reachable "$LINUX_IP" 22; then
        echo "custom_linux"
    elif ssh_reachable "$LINUX_IP" 2333; then
        echo "tuya_linux"
    elif bootloader_reachable; then
        echo "bootloader"
    else
        return 1
    fi
}

# Detect partition layout from flash content
# The original Lidl/Tuya firmware has "/tuya/" paths in the jffs2 partition;
# custom firmware does not.
detect_layout() {
    local image="$1"
    if grep -qao '/tuya/' "$image" 2>/dev/null; then
        echo "lidl"
    else
        echo "custom"
    fi
}

# --- SSH backup --------------------------------------------------------------

# Back up all MTD partitions via SSH cat /dev/mtdX
# Args: ssh_port
backup_via_ssh() {
    local ssh_port="$1"
    local ssh_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

    if [ "$ssh_port" = "2333" ]; then
        ssh_opts="-p ${ssh_port} -o HostKeyAlgorithms=+ssh-rsa ${ssh_opts}"
    else
        ssh_opts="-p ${ssh_port} ${ssh_opts}"
    fi

    # SSH multiplexing: open one connection, reuse for all commands (single password prompt)
    local ssh_ctl
    ssh_ctl=$(mktemp -u /tmp/backup-ssh-XXXXXX)
    ssh_opts="${ssh_opts} -o ControlMaster=auto -o ControlPath=${ssh_ctl} -o ControlPersist=60"
    # shellcheck disable=SC2086
    trap "ssh $ssh_opts -O exit ${SSH_USER}@${LINUX_IP} 2>/dev/null; rm -f ${ssh_ctl}" RETURN

    echo "Connecting to ${LINUX_IP}:${ssh_port}..."
    local proc_mtd
    # shellcheck disable=SC2086
    proc_mtd=$(ssh $ssh_opts "${SSH_USER}@${LINUX_IP}" "cat /proc/mtd") || {
        echo "Error: cannot connect to ${LINUX_IP}:${ssh_port}." >&2
        exit 1
    }

    echo "$proc_mtd"
    echo ""

    # Parse partitions: "mtd0: 00020000 00010000 "boot+cfg""
    local -a mtd_devs=()
    local -a mtd_names=()
    local -a mtd_sizes=()

    while IFS= read -r line; do
        local dev size_hex name
        dev=$(echo "$line" | awk -F: '{print $1}')
        size_hex=$(echo "$line" | awk '{print $2}')
        # Extract quoted name
        name=$(echo "$line" | sed 's/.*"\(.*\)".*/\1/')
        mtd_devs+=("$dev")
        mtd_names+=("$name")
        mtd_sizes+=("$((16#${size_hex}))")
    done < <(echo "$proc_mtd" | tail -n +2)

    local n_parts=${#mtd_devs[@]}
    echo "Found ${n_parts} partitions."
    echo ""

    # Dump each partition
    local i
    for i in $(seq 0 $((n_parts - 1))); do
        local dev="${mtd_devs[$i]}"
        local name="${mtd_names[$i]}"
        local expected="${mtd_sizes[$i]}"
        local outfile="${BACKUP_DIR}/${dev}_${name}.bin"

        echo "Dumping ${dev} (${name}, ${expected} bytes)..."
        # shellcheck disable=SC2086
        ssh $ssh_opts "${SSH_USER}@${LINUX_IP}" "cat /dev/${dev}" > "$outfile" 2>/dev/null

        local actual
        actual=$(stat -c%s "$outfile" 2>/dev/null || echo 0)
        if [ "$actual" -eq "$expected" ]; then
            echo "  ${dev}_${name}.bin: ${actual} bytes [OK]"
        else
            echo "  ${dev}_${name}.bin: ${actual} bytes [EXPECTED: ${expected}] [MISMATCH]" >&2
        fi
    done

    # Concatenate into fullflash.bin
    echo ""
    echo "Creating fullflash.bin..."
    local concat_files=()
    for i in $(seq 0 $((n_parts - 1))); do
        concat_files+=("${BACKUP_DIR}/${mtd_devs[$i]}_${mtd_names[$i]}.bin")
    done
    cat "${concat_files[@]}" > "${BACKUP_DIR}/fullflash.bin"

    # Pad to 16 MB if needed (last partition may not reach end of flash)
    local current_size
    current_size=$(stat -c%s "${BACKUP_DIR}/fullflash.bin" 2>/dev/null || echo 0)
    if [ "$current_size" -lt "$FLASH_SIZE" ]; then
        local pad=$((FLASH_SIZE - current_size))
        echo "Padding fullflash.bin with ${pad} bytes (0xFF) to reach 16 MiB..."
        dd if=/dev/zero bs=1 count="$pad" 2>/dev/null | tr '\0' '\377' >> "${BACKUP_DIR}/fullflash.bin"
    fi
}

# --- bootloader backup -------------------------------------------------------

handle_bootloader() {
    echo "Attempting TFTP backup download (V2 bootloader)..."
    local out
    out=$(timeout 180 tftp -m binary "$BOOT_IP" -c get backup "${BACKUP_DIR}/fullflash.bin" 2>&1) || true

    local tftp_ok=true
    if echo "$out" | grep -qiE \
            "error|timeout|timed out|refused|failed|unknown host|illegal"; then
        tftp_ok=false
    fi

    local size=0
    if [ -f "${BACKUP_DIR}/fullflash.bin" ]; then
        size=$(stat -c%s "${BACKUP_DIR}/fullflash.bin" 2>/dev/null || echo 0)
    fi

    if $tftp_ok && [ "$size" -eq "$FLASH_SIZE" ]; then
        # V2 bootloader — got 16 MB via TFTP GET backup
        echo "Full flash received via TFTP (16 MiB). V2 bootloader detected."
        echo ""
        local layout
        layout=$(detect_layout "${BACKUP_DIR}/fullflash.bin")
        echo "Detected layout: ${layout}"
        echo "Splitting into partitions (${layout} layout)..."
        "$SPLIT_FLASH" "${BACKUP_DIR}/fullflash.bin" "$layout"
    else
        # Old bootloader (Tuya or V1.2) — needs FLR on serial console
        rm -f "${BACKUP_DIR}/fullflash.bin"

        if [ ! -t 0 ]; then
            echo "Error: serial console required for FLR-based backup." >&2
            echo "Old bootloader (Tuya or V1.2) does not support TFTP GET." >&2
            echo "Run this script from an interactive terminal with serial access." >&2
            exit 1
        fi

        echo ""
        echo "TFTP GET failed — old bootloader (Tuya or V1.2)."
        echo "Manual FLR-based backup required."
        echo ""
        echo "On the serial console (<RealTek> prompt), type:"
        echo ""
        echo "    FLR 80500000 00000000 01000000"
        echo ""
        echo "This reads the full 16 MB flash into RAM."
        echo "Wait for the 'FLR OK' message before continuing."
        echo ""
        read -r -p "Press Enter when done... "

        echo ""
        echo "Fetching flash dump via TFTP..."
        out=$(timeout 180 tftp -m binary "$BOOT_IP" -c get test "${BACKUP_DIR}/fullflash.bin" 2>&1) || true

        if echo "$out" | grep -qiE \
                "error|timeout|timed out|refused|failed|unknown host|illegal"; then
            echo "Error: TFTP transfer failed: $out" >&2
            exit 1
        fi

        size=$(stat -c%s "${BACKUP_DIR}/fullflash.bin" 2>/dev/null || echo 0)
        if [ "$size" -ne "$FLASH_SIZE" ]; then
            echo "Error: fullflash.bin is ${size} bytes (expected ${FLASH_SIZE})." >&2
            exit 1
        fi

        echo "Full flash received (16 MiB)."
        echo ""

        local layout
        layout=$(detect_layout "${BACKUP_DIR}/fullflash.bin")
        echo "Detected layout: ${layout}"
        echo "Splitting into partitions (${layout} layout)..."
        "$SPLIT_FLASH" "${BACKUP_DIR}/fullflash.bin" "$layout"
    fi
}

# --- main --------------------------------------------------------------------

check_tftp
resolve_iface "$BOOT_IP"

mkdir -p "$BACKUP_DIR"

# Start logging (duplicate stdout+stderr to backup.log)
exec > >(tee "${BACKUP_DIR}/backup.log") 2>&1

echo "========================================="
echo "  GATEWAY BACKUP"
echo "========================================="
echo ""
echo "Linux IP:    ${LINUX_IP}"
echo "Boot IP:     ${BOOT_IP}"
echo "Output:      ${BACKUP_DIR}"
echo ""

echo "Detecting gateway state..."
STATE=$(detect_state) || {
    echo "Error: gateway unreachable." >&2
    echo "  - No bootloader at ${BOOT_IP}" >&2
    echo "  - No SSH at ${LINUX_IP}:22 (custom firmware)" >&2
    echo "  - No SSH at ${LINUX_IP}:2333 (Tuya firmware)" >&2
    exit 1
}
echo "State: ${STATE}"
echo ""

case "$STATE" in
    custom_linux)
        echo "Backing up via SSH (port 22, custom firmware)..."
        echo ""
        backup_via_ssh 22
        ;;
    tuya_linux)
        echo "Backing up via SSH (port 2333, Tuya firmware)..."
        echo ""
        backup_via_ssh 2333
        ;;
    bootloader)
        echo "Gateway is in bootloader mode."
        echo ""
        handle_bootloader
        ;;
esac

# --- verify ------------------------------------------------------------------

echo ""
echo "========================================="
echo "  VERIFICATION"
echo "========================================="
echo ""

if [ -f "${BACKUP_DIR}/fullflash.bin" ]; then
    size=$(stat -c%s "${BACKUP_DIR}/fullflash.bin" 2>/dev/null || echo 0)
    if [ "$size" -eq "$FLASH_SIZE" ]; then
        md5=$(md5sum "${BACKUP_DIR}/fullflash.bin" | awk '{print $1}')
        echo "fullflash.bin: ${size} bytes (16 MiB) [OK]"
        echo "MD5: ${md5}"
    else
        echo "fullflash.bin: ${size} bytes [EXPECTED: ${FLASH_SIZE}] [MISMATCH]" >&2
    fi
else
    echo "Warning: fullflash.bin not found." >&2
fi

echo ""
echo "Backup files:"
ls -lh "${BACKUP_DIR}/"*.bin 2>/dev/null || echo "  (no .bin files)"
echo ""
echo "Log: ${BACKUP_DIR}/backup.log"
echo ""
echo "Backup complete."
