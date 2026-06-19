#!/bin/bash
# test_button.sh — RTL8196E front-panel reset-button functional test
#
# Exercises the running s40button daemon end-to-end WITHOUT a physical
# press, by forcing the button GPIO low via devmem and watching the
# daemon's syslog reaction.  Validates the three press classes the daemon
# distinguishes plus the issue-#131 LED-restore behaviour.
#
# How the press is faked
#   The button is GPIO line 9 / pad B1 (port B bit 1), active LOW: the pin
#   idles HIGH (pull-up) and the button shorts it to GND.  The s40button
#   daemon reads it through the GPIO cdev as an INPUT.  To simulate a
#   press we drive the SAME pad low from underneath the kernel via devmem:
#       DATA bit9 = 0   then   DIR bit9 = 1  (pad → output-low)
#   The cdev GET_VALUES just reads the DATA register (0x0C), so it now
#   reads 0 = "pressed".  Release = DIR bit9 → 0 (back to input); the
#   pull-up returns the line HIGH.  Only bit 9 is touched (RMW), so the
#   status LED (bit 11) and efr32-nrst (bit 12) on the shared port-B
#   register are left alone.
#   Registers (physical, for devmem): base 0x18003500,
#     CNR 0x18003500  DIR 0x18003508 (1=out)  DATA 0x1800350C
#
# Test classes
#   1. short (>debounce, <5s)      → "press detected" + "short-press ...
#                                    ignored"; recover_efr32 NOT invoked;
#                                    status LED restored to its pre-press
#                                    value (issue #131 — captured at press
#                                    time, not boot time)
#   2. long  (>=5s)  [LONG=1 only] → "long-press detected, invoking
#                                    recover_efr32"; the daemon resets the
#                                    EFR32 radio.  DESTRUCTIVE (drops the
#                                    Zigbee/Thread network for a while) so
#                                    it is opt-in.
#
# (The 300ms debounce is not exercised here: faking the press via devmem
# carries ~200ms of register/fork overhead, too close to the 300ms window
# to produce a reliably sub-debounce pulse — a flaky check is worse than
# none.  The debounce is covered by the daemon's own unit reasoning.)
#
# SAFETY: an EXIT trap always releases the button (restores the pad to
# input).  Without it a Ctrl-C mid-press would leave the pin stuck low and
# the daemon would fire recover_efr32 after 5 s.
#
# Usage:
#   ./scripts/test_button.sh            # blip + short press (safe)
#   LONG=1 ./scripts/test_button.sh     # also the long-press → recover test
#   RTL8196E_IP=10.0.0.1 ./scripts/test_button.sh
#
# J. Nilo — June 2026

set -uo pipefail
export LC_ALL=C

RTL8196E_IP="${RTL8196E_IP:-192.168.1.88}"
RTL8196E_USER="${RTL8196E_USER:-root}"
LONG="${LONG:-0}"
SHORT_HOLD="${SHORT_HOLD:-1.8}"   # >0.3s debounce, <5s → short press
LONG_HOLD="${LONG_HOLD:-6.5}"     # >5s → long press fires recover_efr32
SSH_OPTS=(-o ConnectTimeout=5 -o ServerAliveInterval=3 -o ServerAliveCountMax=2
          -o StrictHostKeyChecking=no -o BatchMode=yes)

# GPIO register addresses (physical) and button bit mask (1<<9 = 512).
DIR_REG=0x18003508
DATA_REG=0x1800350C
BTN=512
LED_PATH="/sys/class/leds/status/brightness"
TRIG_PATH="/sys/class/leds/status/trigger"
LED131="${LED131:-100}"           # distinctive pre-press LED value for #131

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
log(){ echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $1"; }
ok(){ echo -e "${GREEN}  ✓${NC} $1"; PASS=$((PASS+1)); }
bad(){ echo -e "${RED}  ✗${NC} $1"; FAIL=$((FAIL+1)); }
warn(){ echo -e "${YELLOW}  !${NC} $1"; }
info(){ echo -e "${CYAN}  ℹ${NC} $1"; }
PASS=0; FAIL=0

gw(){ timeout 20 ssh "${SSH_OPTS[@]}" "${RTL8196E_USER}@${RTL8196E_IP}" "$@"; }
die(){ echo; echo -e "${RED}  ✗ $1${NC}"; exit 1; }
alive(){ gw 'cat /proc/uptime >/dev/null 2>&1' >/dev/null 2>&1; }
ensure_alive(){ alive || die "Gateway ${RTL8196E_IP} went unreachable (it may have reset). Aborting."; }

# Gateway-side snippets (single-quoted: expanded ON the gateway). Only bit 9
# is RMW'd, so the status LED (bit 11) and efr32-nrst (bit 12) sharing the
# port-B register are left untouched.
PRESS_SEQ='d=$(devmem '"$DATA_REG"' 32); devmem '"$DATA_REG"' 32 $(printf 0x%X $((d & ~'"$BTN"' & 0xFFFFFFFF))); g=$(devmem '"$DIR_REG"' 32); devmem '"$DIR_REG"' 32 $(printf 0x%X $((g | '"$BTN"')))'
RELEASE_SEQ='g=$(devmem '"$DIR_REG"' 32); devmem '"$DIR_REG"' 32 $(printf 0x%X $((g & ~'"$BTN"' & 0xFFFFFFFF))); d=$(devmem '"$DATA_REG"' 32); devmem '"$DATA_REG"' 32 $(printf 0x%X $((d | '"$BTN"')))'

# Hold the button low for $1 seconds, timed ON the gateway (gateway-side
# sleep in the SAME ssh call as press+release) so SSH round-trip latency
# never inflates the press window — without this a 0.15s blip becomes ~1.2s
# (release lands a whole ssh connect later) and slips past the debounce.
hold(){ gw "$PRESS_SEQ; sleep $1; $RELEASE_SEQ" >/dev/null 2>&1 || die "press/hold failed — gateway unreachable?"; }
release(){ gw "$RELEASE_SEQ" >/dev/null 2>&1; }   # trap safety net
btn_state(){ gw "d=\$(devmem $DATA_REG 32); echo \$((d & $BTN))" 2>/dev/null; }  # 0=pressed, 512=released

# Syslog helpers — line count snapshot + new s40button lines since.
# LOG_DUMP is resolved in preflight (this box's syslogd writes to
# /var/log/messages, not the logread shm buffer — handle both).
LOG_DUMP='cat /var/log/messages 2>/dev/null'
logcount(){ gw "$LOG_DUMP | wc -l" 2>/dev/null; }
logsince(){ gw "$LOG_DUMP | tail -n +$(( ${1:-0} + 1 )) | grep -i s40button" 2>/dev/null; }

# ── preflight ──────────────────────────────────────────────────────────
log "Gateway: ${RTL8196E_USER}@${RTL8196E_IP}"
alive || die "Cannot SSH to ${RTL8196E_IP}."

PRE=$(gw '
  pgrep s40button >/dev/null 2>&1 && echo DAEMON_UP || echo DAEMON_DOWN
  command -v devmem >/dev/null 2>&1 && echo HAVE_DEVMEM || echo NO_DEVMEM
  ( [ -s /var/log/messages ] ) && echo HAVE_MESSAGES || echo NO_MESSAGES
  ( command -v logread >/dev/null 2>&1 && [ "$(logread 2>/dev/null | wc -l)" -gt 0 ] ) && echo HAVE_LOGREAD || echo NO_LOGREAD
  [ -x /usr/sbin/recover_efr32 ] && echo HAVE_RECOVER || echo NO_RECOVER
  uname -r
' 2>/dev/null)
KREL=$(echo "$PRE" | tail -1)
info "Kernel: ${KREL}"
echo "$PRE" | grep -q DAEMON_UP    || die "s40button daemon is not running (S40button start it via /userdata/etc/init.d)."
echo "$PRE" | grep -q HAVE_DEVMEM  || die "devmem missing on the gateway — cannot fake a press."
# Resolve the syslog sink: this box's syslogd logs to /var/log/messages;
# a -C syslogd would instead feed the logread shm buffer.
if echo "$PRE" | grep -q HAVE_MESSAGES; then
    LOG_DUMP='cat /var/log/messages 2>/dev/null'; LOG_SRC="/var/log/messages"
elif echo "$PRE" | grep -q HAVE_LOGREAD; then
    LOG_DUMP='logread 2>/dev/null'; LOG_SRC="logread"
else
    die "No readable syslog sink (neither /var/log/messages nor logread carries lines)."
fi
echo "$PRE" | grep -q HAVE_RECOVER || warn "recover_efr32 not found — a long press would log but the action would fail."
ok "daemon running, devmem present, syslog via ${LOG_SRC}"

ST=$(btn_state)
if [ "$ST" != "$BTN" ]; then
    die "Button reads PRESSED ($ST) at start — stuck pin or already held? Aborting."
fi
ok "button idle (released) at start"

# ── save entry state + arrange restore ─────────────────────────────────
ORIG_TRIG=$(gw "cat ${TRIG_PATH}" 2>/dev/null | tr ' ' '\n' | sed -n 's/^\[\(.*\)\]$/\1/p'); ORIG_TRIG="${ORIG_TRIG:-none}"
ORIG_BRIGHT=$(gw "cat ${LED_PATH}" 2>/dev/null || echo 0)
restore(){
    echo
    if ! alive; then warn "Gateway unreachable — skipping restore."; return 0; fi
    log "Releasing button + restoring LED (trigger=${ORIG_TRIG}, brightness=${ORIG_BRIGHT})"
    release
    gw "echo ${ORIG_TRIG} > ${TRIG_PATH} 2>/dev/null; [ '${ORIG_TRIG}' = none ] && echo ${ORIG_BRIGHT} > ${LED_PATH} 2>/dev/null; true" 2>/dev/null
}
trap restore EXIT
info "Entry state saved (LED trigger=[${ORIG_TRIG}] brightness=${ORIG_BRIGHT})"

# Park the LED trigger at none so the daemon's blink + restore are visible
# and deterministic, and seed a distinctive pre-press value for the #131 check.
gw "echo none > ${TRIG_PATH}" 2>/dev/null

# ── Test 1: short press (core, safe) + #131 LED restore ────────────────
echo
log "═══ Test 1 — short press (${SHORT_HOLD}s, < 5s long-press threshold) ═══"
ensure_alive
gw "echo ${LED131} > ${LED_PATH}" 2>/dev/null      # distinctive pre-press LED
info "pre-press LED set to ${LED131} (issue #131: must be restored after release)"
N=$(logcount)
info "button held low (${SHORT_HOLD}s)…"; hold "$SHORT_HOLD"
sleep 0.7
NEW=$(logsince "$N")
echo "$NEW" | sed 's/^/      /'
echo "$NEW" | grep -q "press detected"            && ok "press detected"            || bad "no \"press detected\" logged"
echo "$NEW" | grep -qi "short-press"              && ok "classified as short-press" || bad "not classified as short-press"
if echo "$NEW" | grep -qi "invoking recover_efr32"; then bad "recover_efr32 WRONGLY invoked on a short press"; else ok "recover_efr32 NOT invoked (correct)"; fi
sleep 0.3
LEDNOW=$(gw "cat ${LED_PATH}" 2>/dev/null)
[ "$LEDNOW" = "$LED131" ] && ok "LED restored to pre-press value (${LEDNOW}) — #131 OK" \
                          || bad "LED is ${LEDNOW}, expected ${LED131} (#131 restore regression)"

# ── Test 2: long press → recover_efr32 (opt-in, destructive) ───────────
if [ "$LONG" = "1" ]; then
    echo
    log "═══ Test 2 — long press (${LONG_HOLD}s ≥ 5s) → recover_efr32 ═══"
    warn "DESTRUCTIVE: this resets the EFR32 radio (Zigbee/Thread network drops briefly)."
    ensure_alive
    N=$(logcount)
    info "button held low (${LONG_HOLD}s, daemon should fire at 5s)…"; hold "$LONG_HOLD"
    sleep 1.0
    NEW=$(logsince "$N")
    echo "$NEW" | sed 's/^/      /'
    echo "$NEW" | grep -qi "long-press detected"       && ok "long-press detected"        || bad "no \"long-press detected\" logged"
    echo "$NEW" | grep -qi "invoking recover_efr32"    && ok "recover_efr32 invoked"       || bad "recover_efr32 NOT invoked on long press"
    sleep 0.5
    LEDNOW=$(gw "cat ${LED_PATH}" 2>/dev/null)
    info "LED after long press = ${LEDNOW} (daemon restores pre-press value)"
else
    echo
    info "Test 2 (long press → recover_efr32) skipped — re-run with LONG=1 to exercise it (it resets the radio)."
fi

# ── summary ────────────────────────────────────────────────────────────
echo
log "Result: ${GREEN}${PASS} passed${NC}, $([ "$FAIL" -gt 0 ] && echo "${RED}${FAIL} failed${NC}" || echo "0 failed")"
[ "$FAIL" -gt 0 ] && exit 2
exit 0
