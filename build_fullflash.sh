#!/bin/bash
# build_fullflash.sh — Build a complete 16 MiB flash image for the gateway
#
# Assembles bootloader + kernel + rootfs + userdata into a single fullflash.bin
# that can be written to the SPI NOR flash via TFTP + FLW.
#
# Optionally rebuilds userdata with the chosen network/radio configuration.
#
# Usage: ./build_fullflash.sh [--help]
#
# Environment variables (for non-interactive use):
#   NET_MODE    - "static" or "dhcp" (skip network prompt)
#   IPADDR      - Static IP address (default: 192.168.1.88)
#   NETMASK     - Netmask (default: 255.255.255.0)
#   GATEWAY     - Default gateway (default: 192.168.1.1)
#   RADIO_MODE  - "zigbee" or "thread" (skip radio prompt)
#
# J. Nilo - March 2026

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RTL_DIR="${SCRIPT_DIR}/3-Main-SoC-Realtek-RTL8196E"

BOOTLOADER_IMG="${RTL_DIR}/31-Bootloader/boot.bin"
KERNEL_IMG="${RTL_DIR}/32-Kernel/kernel.img"
ROOTFS_IMG="${RTL_DIR}/33-Rootfs/rootfs.bin"
USERDATA_DIR="${RTL_DIR}/34-Userdata"
USERDATA_IMG="${USERDATA_DIR}/userdata.bin"

OUTPUT="${SCRIPT_DIR}/fullflash.bin"

FLASH_SIZE=$((16 * 1024 * 1024))  # 16 MiB

# Partition offsets (must match kernel DTS)
OFF_BOOT=0x000000      # boot+cfg  128 KiB
OFF_KERNEL=0x020000    # kernel    1920 KiB
OFF_ROOTFS=0x200000    # rootfs    2048 KiB
OFF_USERDATA=0x400000  # userdata  12288 KiB

# --- argument parsing --------------------------------------------------------

while [ $# -gt 0 ]; do
    case "$1" in
        --help|-h)
            echo "Usage: $0 [--help]"
            echo ""
            echo "Builds a complete 16 MiB flash image (fullflash.bin)."
            echo "Asks for network and radio configuration, rebuilds userdata,"
            echo "then assembles all 4 partitions into a single image."
            echo ""
            echo "Environment: NET_MODE, RADIO_MODE, IPADDR, NETMASK, GATEWAY"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

# --- check source images ----------------------------------------------------

echo ""
echo "========================================="
echo "  BUILD FULLFLASH"
echo "========================================="
echo ""

MISSING=0
for f in "$BOOTLOADER_IMG" "$KERNEL_IMG" "$ROOTFS_IMG"; do
    if [ ! -f "$f" ]; then
        echo "Error: $(basename "$f") not found at $f" >&2
        MISSING=1
    fi
done
if [ $MISSING -eq 1 ]; then
    echo "Build the components first (build_bootloader.sh, build_kernel.sh, build_rootfs.sh)." >&2
    exit 1
fi

# --- build userdata ----------------------------------------------------------

ETH0_CONF="${USERDATA_DIR}/skeleton/etc/eth0.conf"
RADIO_CONF="${USERDATA_DIR}/skeleton/etc/radio.conf"

    # Network config
    if [ "${NET_MODE:-}" = "static" ] || [ "${NET_MODE:-}" = "dhcp" ]; then
        net_choice="${NET_MODE}"
    else
        echo "Network configuration:"
        echo "  [1] Static IP (recommended)"
        echo "  [2] DHCP"
        read -r -p "Choice [1]: " net_choice
        net_choice="${net_choice:-1}"
        [ "$net_choice" = "1" ] && net_choice="static"
        [ "$net_choice" = "2" ] && net_choice="dhcp"
    fi

    if [ "$net_choice" = "static" ]; then
        if [ -z "${NET_MODE:-}" ]; then
            read -r -p "IP address [192.168.1.88]: " IPADDR_IN
            read -r -p "Netmask    [255.255.255.0]: " NETMASK_IN
            read -r -p "Gateway    [192.168.1.1]:   " GATEWAY_IN
            IPADDR="${IPADDR_IN:-${IPADDR:-192.168.1.88}}"
            NETMASK="${NETMASK_IN:-${NETMASK:-255.255.255.0}}"
            GATEWAY="${GATEWAY_IN:-${GATEWAY:-192.168.1.1}}"
        else
            IPADDR="${IPADDR:-192.168.1.88}"
            NETMASK="${NETMASK:-255.255.255.0}"
            GATEWAY="${GATEWAY:-192.168.1.1}"
        fi
        printf 'IPADDR=%s\nNETMASK=%s\nGATEWAY=%s\n' "$IPADDR" "$NETMASK" "$GATEWAY" > "$ETH0_CONF"
        echo "→ Static IP: $IPADDR / $NETMASK via $GATEWAY"
    else
        rm -f "$ETH0_CONF"
        echo "→ DHCP"
    fi

    # Radio config
    if [ "${RADIO_MODE:-}" = "zigbee" ] || [ "${RADIO_MODE:-}" = "thread" ]; then
        radio_choice="${RADIO_MODE}"
    else
        echo "Radio mode:"
        echo "  [1] Zigbee (NCP or RCP+zigbeed)"
        echo "  [2] Thread (OTBR)"
        read -r -p "Choice [1]: " radio_choice
        radio_choice="${radio_choice:-1}"
        [ "$radio_choice" = "1" ] && radio_choice="zigbee"
        [ "$radio_choice" = "2" ] && radio_choice="thread"
    fi

    if [ "$radio_choice" = "thread" ]; then
        echo "MODE=otbr" > "$RADIO_CONF"
        echo "→ Thread (OTBR)"
    else
        rm -f "$RADIO_CONF"
        echo "→ Zigbee"
    fi
    echo ""

    echo "Building userdata..."
    "${USERDATA_DIR}/build_userdata.sh" --jffs2-only
    echo ""

    # Cleanup config files (they're now baked into the JFFS2)
    rm -f "$ETH0_CONF" "$RADIO_CONF"

# --- check sizes -------------------------------------------------------------

CVIMG_HDR=16  # cvimg header size

boot_data=$(($(stat -c%s "$BOOTLOADER_IMG") - CVIMG_HDR))
kernel_data=$(stat -c%s "$KERNEL_IMG")           # kept with header
rootfs_data=$(($(stat -c%s "$ROOTFS_IMG") - CVIMG_HDR))
userdata_data=$(($(stat -c%s "$USERDATA_IMG") - CVIMG_HDR))

boot_max=$((OFF_KERNEL - OFF_BOOT))        # 128 KiB
kernel_max=$((OFF_ROOTFS - OFF_KERNEL))    # 1920 KiB
rootfs_max=$((OFF_USERDATA - OFF_ROOTFS))  # 2048 KiB
userdata_max=$((FLASH_SIZE - OFF_USERDATA)) # 12288 KiB

echo "Image sizes (data written to flash):"
echo "  boot.bin:     $(numfmt --to=iec-i --suffix=B $boot_data) / $(numfmt --to=iec-i --suffix=B $boot_max)"
echo "  kernel.img:   $(numfmt --to=iec-i --suffix=B $kernel_data) / $(numfmt --to=iec-i --suffix=B $kernel_max) (with cs6c header)"
echo "  rootfs.bin:   $(numfmt --to=iec-i --suffix=B $rootfs_data) / $(numfmt --to=iec-i --suffix=B $rootfs_max)"
echo "  userdata.bin: $(numfmt --to=iec-i --suffix=B $userdata_data) / $(numfmt --to=iec-i --suffix=B $userdata_max)"
echo ""

OVERFLOW=0
if [ $boot_data -gt $boot_max ]; then
    echo "Error: boot.bin ($boot_data) exceeds boot+cfg partition ($boot_max)" >&2
    OVERFLOW=1
fi
if [ $kernel_data -gt $kernel_max ]; then
    echo "Error: kernel.img ($kernel_data) exceeds kernel partition ($kernel_max)" >&2
    OVERFLOW=1
fi
if [ $rootfs_data -gt $rootfs_max ]; then
    echo "Error: rootfs.bin ($rootfs_data) exceeds rootfs partition ($rootfs_max)" >&2
    OVERFLOW=1
fi
if [ $userdata_data -gt $userdata_max ]; then
    echo "Error: userdata.bin ($userdata_data) exceeds userdata partition ($userdata_max)" >&2
    OVERFLOW=1
fi
if [ $OVERFLOW -eq 1 ]; then exit 1; fi

# --- assemble fullflash.bin --------------------------------------------------

echo "Assembling fullflash.bin (16 MiB)..."

# Start with 16 MiB of 0xFF (erased NOR flash)
dd if=/dev/zero bs=1M count=16 2>/dev/null | tr '\0' '\377' > "$OUTPUT"

# boot+cfg @ 0x000000 — strip 16-byte cvimg header
#   On flash: raw bootloader code (starts with 0bf0...)
tail -c +17 "$BOOTLOADER_IMG" | dd of="$OUTPUT" bs=1 conv=notrunc 2>/dev/null

# kernel @ 0x020000 — KEEP cs6c header (bootloader scans for it at boot)
#   On flash: cs6c header + compressed kernel
dd if="$KERNEL_IMG" of="$OUTPUT" bs=1 seek=$((OFF_KERNEL)) conv=notrunc 2>/dev/null

# rootfs @ 0x200000 — strip 16-byte cvimg header
#   On flash: raw squashfs (starts with hsqs)
tail -c +17 "$ROOTFS_IMG" | dd of="$OUTPUT" bs=1 seek=$((OFF_ROOTFS)) conv=notrunc 2>/dev/null

# userdata @ 0x400000 — strip 16-byte cvimg header
#   On flash: raw JFFS2 (starts with 1985)
tail -c +17 "$USERDATA_IMG" | dd of="$OUTPUT" bs=1 seek=$((OFF_USERDATA)) conv=notrunc 2>/dev/null

# --- verify ------------------------------------------------------------------

echo ""
echo "Verifying..."

ERRORS=0

# Check total size
actual_size=$(stat -c%s "$OUTPUT")
if [ "$actual_size" -ne "$FLASH_SIZE" ]; then
    echo "  FAIL: size is $actual_size (expected $FLASH_SIZE)" >&2
    ERRORS=1
else
    echo "  Size: 16 MiB [OK]"
fi

# Check magic bytes at each partition offset
check_magic() {
    local label="$1" offset="$2" expected="$3"
    local nbytes=$(( ${#expected} / 2 ))
    actual=$(dd if="$OUTPUT" bs=1 skip="$offset" count="$nbytes" 2>/dev/null | xxd -p)
    if [ "$actual" = "$expected" ]; then
        echo "  ${label} @ $(printf '0x%06X' $offset): $expected [OK]"
    else
        echo "  ${label} @ $(printf '0x%06X' $offset): $actual (expected $expected) [FAIL]" >&2
        ERRORS=1
    fi
}

check_magic "boot+cfg" $((OFF_BOOT))     "0bf00004"
check_magic "kernel"   $((OFF_KERNEL))    "63733663"  # cs6c
check_magic "rootfs"   $((OFF_ROOTFS))    "68737173"  # hsqs
check_magic "userdata" $((OFF_USERDATA))  "1985"       # JFFS2 magic

if [ $ERRORS -ne 0 ]; then
    echo ""
    echo "VERIFICATION FAILED — do not flash this image." >&2
    rm -f "$OUTPUT"
    exit 1
fi

echo ""
echo "========================================="
echo "  FULLFLASH READY"
echo "========================================="
echo ""
echo "  $(ls -lh "$OUTPUT" | awk '{print $NF, $5}')"
echo "  MD5: $(md5sum "$OUTPUT" | awk '{print $1}')"
echo ""
