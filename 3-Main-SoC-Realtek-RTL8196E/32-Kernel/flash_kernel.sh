#!/bin/bash
# flash_kernel.sh — Flash kernel partition via TFTP
#
# The device must be in download mode (<RealTek> prompt) before running.
# WARNING: Flashing the kernel triggers an automatic reboot.
#
# Usage:
#   ./flash_kernel.sh                         # flash kernel-6.18.img
#   ./flash_kernel.sh -i <file>               # flash an explicit file
#   ./flash_kernel.sh 192.168.1.6             # override target IP (positional)
#
# Options:
#   -i, --image FILE    Explicit image filename (default: kernel-6.18.img)
#
# Environment variables (optional, for non-interactive use):
#   CONFIRM=y              Skip the "Proceed?" prompt
#
# J. Nilo - December 2025, unified April 2026

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Shared safe-retry TFTP upload helper (probe_tftp_wrq, tftp_put_safe).
. "$SCRIPT_DIR/../../lib/flash_tftp.sh"

# ── Argument parsing ──────────────────────────────────────────────────────

IMAGE_OVERRIDE=""
POS_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        -i|--image)
            IMAGE_OVERRIDE="$2"; shift 2 ;;
        --image=*)
            IMAGE_OVERRIDE="${1#*=}"; shift ;;
        -h|--help)
            sed -n '2,16p' "$0" | sed 's|^# \{0,1\}||'
            exit 0 ;;
        *)
            POS_ARGS+=("$1"); shift ;;
    esac
done

TARGET_IP="${POS_ARGS[0]:-192.168.1.6}"

# Resolve image path
if [ -n "$IMAGE_OVERRIDE" ]; then
    case "$IMAGE_OVERRIDE" in
        /*) IMAGE="$IMAGE_OVERRIDE" ;;
        *)  IMAGE="${SCRIPT_DIR}/${IMAGE_OVERRIDE}" ;;
    esac
else
    IMAGE="${SCRIPT_DIR}/kernel-6.18.img"
fi

# Check prerequisites
tftp_usage="$(tftp --help 2>&1 || true)"
if ! command -v tftp >/dev/null 2>&1 || ! echo "$tftp_usage" | grep -q '\-c'; then
    echo "Error: tftp-hpa client not found (need the -c flag)." >&2
    echo "Install it with: sudo apt install tftp-hpa" >&2
    exit 1
fi
if ! command -v nc >/dev/null 2>&1; then
    echo "Error: netcat (nc) not found." >&2
    echo "Install it with: sudo apt install netcat-openbsd" >&2
    exit 1
fi

if [ ! -f "$IMAGE" ]; then
    echo "Error: $(basename "$IMAGE") not found at ${IMAGE}"
    echo "Run ./build_kernel.sh first"
    exit 1
fi

IMAGE_BASENAME="$(basename "$IMAGE")"

SIZE=$(stat -c%s "$IMAGE" 2>/dev/null || stat -f%z "$IMAGE")

if [ "${BOOTLOADER_CONFIRMED:-}" != "1" ]; then
    echo "Checking if gateway is in boot mode..."

    IFACE="$(ip route get "$TARGET_IP" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
    if [ -z "${IFACE:-}" ]; then
        echo "Error: cannot determine outgoing interface to ${TARGET_IP} (ip route get failed)." >&2
        exit 1
    fi

    if ip route get "$TARGET_IP" 2>/dev/null | grep -qE '\svia\s'; then
        echo "Error: ${TARGET_IP} is reached via a gateway (routed). Must be same L2 segment." >&2
        exit 1
    fi

    TRIES="${TRIES:-10}"
    PORT="${PORT:-69}"
    SLEEP_BETWEEN="${SLEEP_BETWEEN:-0.2}"

    ok=0
    for _ in $(seq 1 "$TRIES"); do
        bash -c 'echo -n X > /dev/udp/'"$TARGET_IP"'/'"$PORT"'' >/dev/null 2>&1 || true
        sleep 0.2
        LINE="$(ip neigh show "$TARGET_IP" dev "$IFACE" 2>/dev/null || true)"
        if echo "$LINE" | grep -qiE 'lladdr [0-9a-f]{2}(:[0-9a-f]{2}){5}'; then
            ok=1
            break
        fi
        sleep "$SLEEP_BETWEEN"
    done

    if [ "$ok" -ne 1 ]; then
        echo "Error: ${TARGET_IP} unreachable — check cable and that device is in download mode." >&2
        exit 1
    fi
fi

echo ""
echo "Flashing ${IMAGE_BASENAME} (${SIZE} bytes) to ${TARGET_IP}..."
echo ""
if [ "${CONFIRM:-}" != "y" ]; then
    read -r -p "Proceed? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        echo "Aborted."
        echo "To flash manually: tftp -m binary ${TARGET_IP} -c put ${IMAGE_BASENAME}"
        exit 0
    fi
fi

NOTIFY_PORT=9999
NOTIFY_TMO=60

notify_file=$(mktemp)
(timeout "$NOTIFY_TMO" nc -u -l -p "$NOTIFY_PORT" > "$notify_file" 2>/dev/null) &
nc_pid=$!
sleep 0.2

cd "$SCRIPT_DIR"
if ! tftp_put_safe "$TARGET_IP" "$IMAGE_BASENAME" 3 30 >/dev/null; then
    kill "$nc_pid" 2>/dev/null; wait "$nc_pid" 2>/dev/null; rm -f "$notify_file"
    echo "Error: transfer failed after retries." >&2
    exit 1
fi
echo "Uploaded. Waiting for flash write..."
while kill -0 "$nc_pid" 2>/dev/null; do
    [ -s "$notify_file" ] && { kill "$nc_pid" 2>/dev/null; break; }
    sleep 0.5
done
wait "$nc_pid" 2>/dev/null || true
result=$(tr -d '\0' < "$notify_file")
rm -f "$notify_file"

if [ "$result" = "OK" ]; then
    echo "Flash Write Succeeded."
elif [ "$result" = "FAIL" ]; then
    echo "Error: flash write FAILED on gateway." >&2
    exit 1
else
    echo "Warning: no notification received (timeout ${NOTIFY_TMO}s)." >&2
    echo "Check the serial console for status."
fi
echo ""
echo "Done."
echo "Bootloader V2.5+ reboots automatically."
echo "Older versions: J BFC00000 (serial console) or hard reset."
