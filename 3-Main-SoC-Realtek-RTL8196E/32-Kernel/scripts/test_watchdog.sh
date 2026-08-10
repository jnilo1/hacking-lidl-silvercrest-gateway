#!/bin/bash
# test_watchdog.sh — RTL8196E hardware-watchdog functional test
#
# Verifies the rtl819x-wdt driver end-to-end: that the chip is armed and
# being fed, and (opt-in) that a kernel panic is turned into a fast
# hardware reset which leaves a v9 post-mortem record in the reserved DRAM
# page — read back, decoded and persisted on the next boot.
#
# Two phases:
#
#   Phase 1 (always, NON-destructive)
#     - /dev/watchdog present, BusyBox feeder running (S25watchdog)
#     - WDTCNR shows the chip ARMED (WDTE byte != 0xA5)
#     - driver reports "record v9", and the last-reset cause line
#     - shows any panic record already captured this boot (dmesg +
#       /userdata/panic/history)
#
#   Phase 2 (opt-in TRIGGER=1, DESTRUCTIVE — reboots the gateway)
#     Fires `echo c > /proc/sysrq-trigger`.  sysrq_handle_crash() calls
#     panic() straight away — there is no NULL-deref and no oops on the way,
#     so this needs sysrq enabled but does NOT depend on panic_on_oops.
#     The wdt panic notifier arms a ~1.31 s reset and then writes the v9
#     record.  The script then waits for the reboot and checks:
#       - the box came back
#       - dmesg carries "previous panic: ... reason=..."
#       - the record is v9 (cause/status/softirq/WDTCNR fields)
#       - its uptime matches the pre-panic uptime (right boot captured)
#       - S26panicrec persisted the line to /userdata/panic/history
#       - the watchdog re-armed + the feeder is back
#
# A sysrq panic is process-context (no IRQ regs), so EPC/RA are expected
# empty — the point here is the record write→survive-reset→
# decode→persist chain, not a storm capture.  After the test
# /userdata/panic/history holds the sysrq record; `rm` it to re-arm.
#
# Usage:
#   ./scripts/test_watchdog.sh           # Phase 1 only (safe)
#   TRIGGER=1 ./scripts/test_watchdog.sh # + Phase 2 (panics & reboots .88)
#   RTL8196E_IP=10.0.0.1 ./scripts/test_watchdog.sh
#
# J. Nilo — June 2026

set -uo pipefail
export LC_ALL=C

# Gateway address: RTL8196E_IP env > gateway.env > the last gateway installed
# or reached > its hostname > the historic 192.168.1.88 (see lib/gwconf.sh).
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../../../lib/gwconf.sh"
RTL8196E_IP="${RTL8196E_IP:-$(gwconf_gateway_addr)}"
RTL8196E_USER="${RTL8196E_USER:-root}"
TRIGGER="${TRIGGER:-0}"
REBOOT_WAIT="${REBOOT_WAIT:-180}"      # max seconds to wait for the box to return
SSH_OPTS=(-o ConnectTimeout=5 -o ServerAliveInterval=3 -o ServerAliveCountMax=2
          -o StrictHostKeyChecking=no -o BatchMode=yes)

WDTCNR=0x1800311c                      # WDTCNR (physical, for devmem)
WDT_DEV=/dev/watchdog
PANIC_HIST=/userdata/panic/history

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
log(){ echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $1"; }
ok(){ echo -e "${GREEN}  ✓${NC} $1"; PASS=$((PASS+1)); }
bad(){ echo -e "${RED}  ✗${NC} $1"; FAIL=$((FAIL+1)); }
warn(){ echo -e "${YELLOW}  !${NC} $1"; }
info(){ echo -e "${CYAN}  ℹ${NC} $1"; }
PASS=0; FAIL=0

gw(){ timeout 15 ssh "${SSH_OPTS[@]}" "${RTL8196E_USER}@${RTL8196E_IP}" "$@"; }
die(){ echo; echo -e "${RED}  ✗ $1${NC}"; exit 1; }
alive(){ gw 'cat /proc/uptime >/dev/null 2>&1' >/dev/null 2>&1; }

# ── Phase 1 — non-destructive verification ─────────────────────────────
log "Gateway: ${RTL8196E_USER}@${RTL8196E_IP}"
alive || die "Cannot SSH to ${RTL8196E_IP}."

PRE=$(gw "
  [ -c ${WDT_DEV} ] && echo HAVE_WDT || echo NO_WDT
  ps -w 2>/dev/null | grep -q '[w]atchdog -t' && echo HAVE_FEEDER || echo NO_FEEDER
  command -v devmem >/dev/null 2>&1 && echo HAVE_DEVMEM || echo NO_DEVMEM
  echo SYSRQ=\$(cat /proc/sys/kernel/sysrq 2>/dev/null)
  echo PANICOOPS=\$(cat /proc/sys/kernel/panic_on_oops 2>/dev/null)
  uname -r
" 2>/dev/null)
info "Kernel: $(echo "$PRE" | tail -1)"
echo "$PRE" | grep -q HAVE_WDT    || die "${WDT_DEV} absent (CONFIG_RTL819X_WDT off, or driver did not probe)."
echo "$PRE" | grep -q HAVE_DEVMEM || die "devmem missing on the gateway."
echo "$PRE" | grep -q HAVE_FEEDER && ok "BusyBox watchdog feeder running (S25watchdog)" \
                                   || bad "no watchdog feeder running — the chip is not being fed"

WB=$(gw "w=\$(devmem ${WDTCNR} 32); echo \$w \$(( (w >> 24) & 0xFF ))" 2>/dev/null)
WREG=$(echo "$WB" | awk '{print $1}'); WBYTE=$(echo "$WB" | awk '{print $2}')
if [ "$WBYTE" = "165" ]; then   # 0xA5
    bad "watchdog DISABLED (WDTCNR=${WREG}, WDTE=0xA5)"
else
    ok "watchdog ARMED (WDTCNR=${WREG}, WDTE byte=$(printf 0x%02X "$WBYTE") != 0xA5)"
fi

gw 'dmesg 2>/dev/null | grep -i "rtl819x-wdt"' 2>/dev/null | sed 's/^/      /'
gw 'dmesg 2>/dev/null | grep -i "rtl819x-wdt" | grep -q "record v9"' 2>/dev/null \
    && ok "driver reports record v9" || warn "driver did not report record v9 (older driver?)"

SYSRQ=$(echo "$PRE" | sed -n 's/^SYSRQ=//p'); PANICOOPS=$(echo "$PRE" | sed -n 's/^PANICOOPS=//p')
info "sysrq=${SYSRQ:-?}  panic_on_oops=${PANICOOPS:-?}"

echo
log "Existing panic record (if any):"
EXIST=$(gw "dmesg 2>/dev/null | grep -F 'previous panic:'" 2>/dev/null)
if [ -n "$EXIST" ]; then echo "$EXIST" | sed 's/^/      /'; else info "none in this boot's dmesg"; fi
HIST=$(gw "cat ${PANIC_HIST} 2>/dev/null" 2>/dev/null)
if [ -n "$HIST" ]; then info "persisted ${PANIC_HIST}:"; echo "$HIST" | sed 's/^/      /'; else info "${PANIC_HIST}: none"; fi

# ── Phase 2 — destructive trigger ──────────────────────────────────────
if [ "$TRIGGER" != "1" ]; then
    echo
    info "Phase 2 (panic → watchdog reset → record) skipped."
    info "Re-run with TRIGGER=1 to fire it — it PANICS and REBOOTS ${RTL8196E_IP}."
    echo
    log "Result: ${GREEN}${PASS} passed${NC}, $([ "$FAIL" -gt 0 ] && echo "${RED}${FAIL} failed${NC}" || echo "0 failed") (Phase 1)"
    [ "$FAIL" -gt 0 ] && exit 2 || exit 0
fi

# sysrq-c reaches panic() directly, so panic_on_oops plays no part here: it is
# reported above for context but must never gate the test.
if [ "${SYSRQ:-0}" = "0" ]; then
    die "sysrq disabled (=$SYSRQ) — sysrq-c would not fire. Aborting."
fi

echo
log "═══ Phase 2 — panic → watchdog reset → v9 record ═══"
warn "DESTRUCTIVE: this panics and reboots the gateway. Keep the serial console in view."

# Re-arm the one-shot persistence and snapshot the pre-panic uptime.
gw "rm -f ${PANIC_HIST}" 2>/dev/null
U0=$(gw 'cut -d. -f1 /proc/uptime' 2>/dev/null)
info "pre-panic uptime ${U0}s; cleared ${PANIC_HIST}; firing sysrq-c…"

# Fire the crash. The box panics synchronously, so this ssh never returns
# cleanly — cap it and ignore the result.
timeout 8 ssh "${SSH_OPTS[@]}" "${RTL8196E_USER}@${RTL8196E_IP}" \
    'echo c > /proc/sysrq-trigger' >/dev/null 2>&1 || true

# Wait for the reboot: SSH back AND a fresh (small) uptime.
log "waiting for reboot (up to ${REBOOT_WAIT}s)…"
sleep 8
waited=8; back=""
while [ "$waited" -lt "$REBOOT_WAIT" ]; do
    u=$(gw 'cut -d. -f1 /proc/uptime' 2>/dev/null)
    if [ -n "$u" ] && [ "$u" -lt 120 ] 2>/dev/null; then back="$u"; break; fi
    sleep 5; waited=$((waited+5))
done
if [ -z "$back" ]; then
    bad "gateway did not return within ${REBOOT_WAIT}s — check the serial console; a DRAM-scribble boot-loop may need a power-cycle."
    echo
    log "Result: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
    exit 2
fi
ok "gateway rebooted and is back (uptime ${back}s)"

# Read back the decoded record from this boot's dmesg.
sleep 2
REC=$(gw "dmesg 2>/dev/null | grep -F 'previous panic:'" 2>/dev/null)
if [ -n "$REC" ]; then
    ok "panic record decoded on reboot"
    echo "$REC" | sed 's/^/      /'
else
    bad "no 'previous panic:' line in dmesg — record not written/read"
fi

# v9 fields present?
if echo "$REC" | grep -q "cause=" && echo "$REC" | grep -q "status=" && \
   echo "$REC" | grep -q "softirq=" && echo "$REC" | grep -q "wdt="; then
    ok "record is v9 (cause/status/softirq/wdt fields present)"
else
    bad "v9 fields (cause=/status=/softirq=/wdt=) missing — record malformed or older?"
fi

# Recorded uptime ≈ pre-panic uptime?
RU=$(echo "$REC" | sed -n 's/.*uptime=\([0-9]*\)s.*/\1/p')
if [ -n "$RU" ] && [ -n "$U0" ]; then
    d=$(( RU > U0 ? RU - U0 : U0 - RU ))
    if [ "$d" -le 30 ]; then ok "record uptime=${RU}s matches pre-panic ${U0}s (Δ${d}s)"
    else bad "record uptime=${RU}s vs pre-panic ${U0}s (Δ${d}s > 30s — wrong boot?)"; fi
else
    warn "could not compare record uptime (RU=${RU:-?} U0=${U0:-?})"
fi

# S26panicrec persisted it?
HIST=$(gw "cat ${PANIC_HIST} 2>/dev/null" 2>/dev/null)
if echo "$HIST" | grep -qF 'previous panic:'; then
    ok "S26panicrec persisted the record to ${PANIC_HIST}"
    echo "$HIST" | sed 's/^/      /'
else
    bad "${PANIC_HIST} not written by S26panicrec"
fi

# Re-armed after reboot?
WB=$(gw "w=\$(devmem ${WDTCNR} 32); echo \$(( (w >> 24) & 0xFF ))" 2>/dev/null)
[ "$WB" != "165" ] && ok "watchdog re-armed after reboot (WDTE=$(printf 0x%02X "$WB"))" \
                    || bad "watchdog NOT re-armed after reboot (WDTE=0xA5)"
gw "ps -w 2>/dev/null | grep -q '[w]atchdog -t'" 2>/dev/null \
    && ok "feeder running again" || bad "feeder not running after reboot"

echo
info "Note: ${PANIC_HIST} now holds the sysrq panic record — 'rm' it on the gateway to re-arm capture."
log "Result: ${GREEN}${PASS} passed${NC}, $([ "$FAIL" -gt 0 ] && echo "${RED}${FAIL} failed${NC}" || echo "0 failed")"
[ "$FAIL" -gt 0 ] && exit 2 || exit 0
