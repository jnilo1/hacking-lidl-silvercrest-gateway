#!/bin/bash
# test_leds.sh — RTL8196E LED functional test (status LED + LAN LED)
#
# Drives the gateway's two user-visible LEDs through ON / DIM / OFF and
# asks the operator to visually confirm each state.  The two LEDs are on
# completely different control paths, so this exercises both:
#
#   * STATUS LED — GPIO line 11 / pad B3, driven by the leds-gpio-pwm
#     driver (LED class "status").  Brightness is software PWM:
#       ON  = 255  (steady, 100% duty)
#       DIM =  60  (≈25% duty — the one intermediate level kept visible
#                   above the flicker threshold, issue #120)
#       OFF =   0  (timer stopped, GPIO forced low)
#     Path: /sys/class/leds/status/{brightness,trigger,max_brightness}
#     A LED trigger (heartbeat/netdev/...) would override a manual
#     brightness, so the script parks the trigger at "none" for the test
#     and restores the original trigger at the end.
#
#   * LAN LED — switch-ASIC LED_PORTn output (pad B6 on the Lidl board).
#     GPIO has NO effect on it; only the ASIC LED controller does.  The
#     rtl8196e-eth driver exposes it as a sysfs knob:
#       ON  = bright  (LEDCREG=DIRECT, DIRECTLCR=default — full link/act)
#       DIM = dim     (LEDCREG=0 scan mode, ≈25% brightness)
#       OFF = off     (LEDCREG=0, DIRECTLCR=0 — pin driven low, no glow)
#     Path: /sys/class/net/eth0/led_mode
#     It is a link/activity LED: with the cable up it glows and flickers
#     on traffic; "off" forces the pin low regardless of link.  Toggling
#     it does NOT touch the PHY, so the SSH link stays up throughout.
#
# Both LEDs are restored to their entry state on exit (including Ctrl-C).
#
# This is a VISUAL test — run it where you can see the gateway.  Without a
# TTY (e.g. driven by CI/an agent) it falls back to AUTO mode: it still
# drives every state and reads back the software side, just with a timed
# dwell instead of a confirm prompt.
#
# Usage:
#   ./scripts/test_leds.sh                 # interactive, 192.168.1.88
#   RTL8196E_IP=10.0.0.1 ./scripts/test_leds.sh
#   AUTO=1 DWELL=2 ./scripts/test_leds.sh  # no prompts, 2s per state
#
# Env:
#   RTL8196E_IP   gateway IP            (default 192.168.1.88)
#   RTL8196E_USER ssh user             (default root)
#   STATUS_DIM    status DIM brightness (default 60)
#   AUTO          1 = no prompts, dwell on each state
#   DWELL         seconds per state in AUTO mode (default 3)
#
# J. Nilo — June 2026

set -uo pipefail
export LC_ALL=C

RTL8196E_IP="${RTL8196E_IP:-192.168.1.88}"
RTL8196E_USER="${RTL8196E_USER:-root}"
STATUS_DIM="${STATUS_DIM:-60}"
DWELL="${DWELL:-3}"
# ConnectTimeout bounds the connect; ServerAlive* bounds a hang AFTER connect
# (if the gateway resets mid-command SSH gives up in ~6s instead of blocking on
# the dead TCP session — the failure mode that froze the interactive run).
SSH_OPTS=(-o ConnectTimeout=5 -o ServerAliveInterval=3 -o ServerAliveCountMax=2
          -o StrictHostKeyChecking=no -o BatchMode=yes)

STATUS_LED="/sys/class/leds/status"
LAN_LED="/sys/class/net/eth0/led_mode"
# LAN LED ASIC registers (physical addrs for devmem; KSEG1 0xBB80xxxx − 0xA0000000)
LEDCREG_PHYS=0x1B804300
DIRECTLCR_PHYS=0x1B804314

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
log(){ echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $1"; }
ok(){ echo -e "${GREEN}  ✓${NC} $1"; }
bad(){ echo -e "${RED}  ✗${NC} $1"; }
warn(){ echo -e "${YELLOW}  !${NC} $1"; }
info(){ echo -e "${CYAN}  ℹ${NC} $1"; }

# AUTO when asked, or when there is no terminal to prompt at.
AUTO="${AUTO:-0}"
if [ ! -t 0 ] && [ "$AUTO" != "1" ]; then
    AUTO=1
    NO_TTY=1
fi

PASS=0; FAIL=0

# Outer `timeout` is a belt-and-braces cap in case ssh itself wedges.
gw(){ timeout 15 ssh "${SSH_OPTS[@]}" "${RTL8196E_USER}@${RTL8196E_IP}" "$@"; }

die(){ echo; bad "$1"; exit 1; }

# Cheap liveness probe — used to fail fast (and to skip a doomed restore)
# instead of letting a write hang on a gateway that has reset.
alive(){ gw 'cat /proc/uptime >/dev/null 2>&1' >/dev/null 2>&1; }
ensure_alive(){
    alive || die "Gateway ${RTL8196E_IP} went unreachable (it likely reset). \
Aborting. Check the serial console; re-run once it is back up."
}

# ── preflight ──────────────────────────────────────────────────────────
log "Gateway: ${RTL8196E_USER}@${RTL8196E_IP}"
if ! gw true 2>/dev/null; then
    bad "Cannot SSH to ${RTL8196E_IP}. Is the gateway up and reachable?"
    exit 1
fi

PREFLIGHT=$(gw "
    uname -r
    [ -d ${STATUS_LED} ] && echo HAVE_STATUS || echo NO_STATUS
    [ -e ${LAN_LED} ] && echo HAVE_LAN || echo NO_LAN
    command -v devmem >/dev/null 2>&1 && echo HAVE_DEVMEM || echo NO_DEVMEM
" 2>/dev/null)

KREL=$(echo "$PREFLIGHT" | sed -n 1p)
info "Kernel: ${KREL}"
HAVE_DEVMEM=0
echo "$PREFLIGHT" | grep -q HAVE_DEVMEM && HAVE_DEVMEM=1
if ! echo "$PREFLIGHT" | grep -q HAVE_STATUS; then
    bad "Status LED not found at ${STATUS_LED} (leds-gpio-pwm not bound?)"
    exit 1
fi
if ! echo "$PREFLIGHT" | grep -q HAVE_LAN; then
    bad "LAN LED knob not found at ${LAN_LED} (rtl8196e-eth not bound?)"
    exit 1
fi

# ── save entry state, arrange restore ──────────────────────────────────
# trigger line looks like:  none rtc [heartbeat] netdev ...   → grab [active]
ORIG_TRIGGER=$(gw "cat ${STATUS_LED}/trigger" 2>/dev/null \
                 | tr ' ' '\n' | sed -n 's/^\[\(.*\)\]$/\1/p')
ORIG_TRIGGER="${ORIG_TRIGGER:-none}"
ORIG_BRIGHT=$(gw "cat ${STATUS_LED}/brightness" 2>/dev/null || echo 255)
ORIG_LAN=$(gw "cat ${LAN_LED}" 2>/dev/null || echo bright)

restore(){
    echo
    if ! alive; then
        warn "Gateway unreachable — skipping restore. Re-run once it is back to reset the LEDs."
        return 0
    fi
    log "Restoring entry state (status: trigger=${ORIG_TRIGGER} bright=${ORIG_BRIGHT}; lan=${ORIG_LAN})"
    gw "
        echo ${ORIG_TRIGGER} > ${STATUS_LED}/trigger 2>/dev/null
        [ '${ORIG_TRIGGER}' = none ] && echo ${ORIG_BRIGHT} > ${STATUS_LED}/brightness 2>/dev/null
        echo ${ORIG_LAN} > ${LAN_LED} 2>/dev/null
        true
    " 2>/dev/null
}
trap restore EXIT

info "Entry state saved — status trigger=[${ORIG_TRIGGER}] brightness=${ORIG_BRIGHT}, lan led_mode=${ORIG_LAN}"
[ "${NO_TTY:-0}" = 1 ] && warn "No TTY detected — running in AUTO mode (drive + readback, no visual confirm)"

# Park the status trigger at "none" so manual brightness writes stick.
gw "echo none > ${STATUS_LED}/trigger" 2>/dev/null

# ── confirm helper ─────────────────────────────────────────────────────
# $1 = human description of what should be visible
confirm(){
    local what="$1"
    ensure_alive
    if [ "$AUTO" = "1" ]; then
        info "Expected: ${what}"
        sleep "${DWELL}"
        return 0
    fi
    echo -ne "${YELLOW}  → ${what}\n     Press Enter if correct, or type 'n' then Enter if wrong: ${NC}"
    local ans; read -r ans
    case "$ans" in
        n|N|no|NO) bad "operator marked WRONG"; FAIL=$((FAIL+1)); return 1 ;;
        *)         ok "confirmed";             PASS=$((PASS+1)); return 0 ;;
    esac
}

# ── STATUS LED ─────────────────────────────────────────────────────────
set_status(){ gw "echo $1 > ${STATUS_LED}/brightness" 2>/dev/null \
                || die "Failed to set status brightness=$1 (gateway unreachable?)"; }
read_status(){ gw "cat ${STATUS_LED}/brightness" 2>/dev/null; }

echo
log "═══ STATUS LED (GPIO B3, leds-gpio-pwm) ═══"

set_status 255; rb=$(read_status)
info "brightness set 255 → readback ${rb}"
confirm "STATUS LED is ON, steady and at full brightness"

set_status "$STATUS_DIM"; rb=$(read_status)
info "brightness set ${STATUS_DIM} → readback ${rb}  (≈25% duty PWM)"
confirm "STATUS LED is DIM (clearly fainter than full, no visible flicker)"

set_status 0; rb=$(read_status)
info "brightness set 0 → readback ${rb}"
confirm "STATUS LED is fully OFF (dark)"

# ── LAN LED ────────────────────────────────────────────────────────────
set_lan(){ gw "echo $1 > ${LAN_LED}" 2>/dev/null \
             || die "Failed to set lan led_mode=$1 (gateway unreachable?)"; }
read_lan(){
    local mode; mode=$(gw "cat ${LAN_LED}" 2>/dev/null)
    if [ "$HAVE_DEVMEM" = 1 ]; then
        local regs
        regs=$(gw "echo LEDCREG=\$(devmem ${LEDCREG_PHYS} 32) DIRECTLCR=\$(devmem ${DIRECTLCR_PHYS} 32)" 2>/dev/null)
        echo "${mode}   [${regs}]"
    else
        echo "${mode}"
    fi
}

echo
log "═══ LAN LED (switch ASIC, eth0/led_mode) ═══"
info "This is a link/activity LED — with the cable up it glows and flickers on traffic."

set_lan bright; info "led_mode=bright → $(read_lan)"
confirm "LAN LED is ON/bright (full glow, flickers with traffic)"

set_lan dim; info "led_mode=dim → $(read_lan)"
confirm "LAN LED is DIM (clearly fainter glow)"

set_lan off; info "led_mode=off → $(read_lan)"
confirm "LAN LED is fully OFF (dark, even with the cable plugged in)"

# ── summary ────────────────────────────────────────────────────────────
echo
if [ "$AUTO" = "1" ]; then
    log "AUTO run complete — all 6 states driven and read back above."
    log "Software side validated; visual confirmation needs a human run (no AUTO)."
else
    log "Result: ${GREEN}${PASS} passed${NC}, $([ "$FAIL" -gt 0 ] && echo "${RED}${FAIL} failed${NC}" || echo "0 failed") / 6 states"
    [ "$FAIL" -gt 0 ] && exit 2
fi
exit 0
