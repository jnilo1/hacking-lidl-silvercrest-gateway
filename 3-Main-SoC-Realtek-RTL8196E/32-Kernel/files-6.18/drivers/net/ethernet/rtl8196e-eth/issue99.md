# Issue #99 — RTL8196E soft-lockup: root mechanism and proposed fix

**Status:** root mechanism identified and code-verified; RC1 shipped (v4.0.0-rc2) and
**recurred in the field after ~4.3 days** — see §12. Detector left unchanged; the watchdog
panic record extended to **v6** to capture the eth recovery + switch-core/TX/ring state so
the next field crash disambiguates the three surviving hypotheses (§12) before any further
code change. **Date:** 2026-06-19, updated 2026-06-24.
**Audience:** senior kernel/driver reviewer. Everything below cites `file:line` against the
in-tree driver (working tree = driver **v2.14**) and notes equivalence to the field build
**v2.7** (shipped as `v3.8.5`). All line numbers are from this driver directory.

---

## 1. TL;DR

Issue #99 is a **self-sustaining `PKTHDR_DESC_RUNOUT` interrupt storm**. Once the switch's RX
descriptor pointer and the driver's `rx_idx` cursor disagree, the ISR → NAPI-poll → re-enable
handshake becomes a closed loop that does **zero work** yet keeps re-arming the same interrupt,
pinning the CPU in the NET_RX softirq (`__napi_poll`) until the hardware watchdog reboots.

The previously shipped fix **ETHDRV-013** (RX resync inside `rtl8196e_tx_timeout`) is correct
but **insufficient**: it only closes *one* entry into the desync (the TX-watchdog recovery
path). A field unit running v2.7 — which already contains ETHDRV-013 — hit #99 again. The
adversarial code review concluded the storm is **self-sustaining regardless of how it is
entered**, so the durable fix must **break the handshake itself**, not patch individual
triggers. That is the proposed **RC1** (§8).

---

## 2. The bug

**Signature (every field capture):** CPU pinned 100% in softirq, `epc =
arch_local_irq_enable`, `ra = handle_softirqs`, pending softirq mask `0xa = TIMER|NET_RX`,
the soft-lockup detector firing off the timer IRQ. The timer wheel is **frozen (a victim of
the storm, not its cause)** — pending-timer counts stay normal while the wheel cannot advance.

**record-v4 watchdog captures additionally show `napi=[rtl8196e_poll]`** — at the instant of
the hang the CPU is inside the Ethernet driver's NAPI receive poll.

**Field history:** intermittent across multiple units (hours to days to trigger). Latest
capture (olivluca): `uptime=319396s` (~3.7 days), `napi=[rtl8196e_poll]`, driver banner
reports **`rtl8196e-eth … v2.7`**, kernel `6.18.24-rtl8196e`.

---

## 3. What was already ruled out (do not re-litigate)

- **Timer-wheel / hrtimer "catch-up storm"** — the timer wheel is the **victim**: it is
  starved because the CPU never leaves the NET_RX softirq. Pending-timer sets in the captures
  are the normal routine set, not a runaway. Not the cause.
- **`hrtimer: interrupt took N ns`** — a benign `pr_warn_once` from the coarse 25 kHz
  clockevent; field-observed to fire once and the box keep running cleanly. Decoupled from #99.
- **Missing `CPUIISR` W1C in `rtl8196e_tx_timeout`** — `tx_timeout` does not explicitly
  write-1-clear `CPUIISR`, unlike `stop()`/`hw_init()` (`hw.c` `rtl8196e_hw_init` clears it).
  This is **not** the engine: the ISR W1Cs `CPUIISR` on every entry (`main.c:468`) and the
  poll re-W1Cs the RUNOUT bits (`main.c:444`), so a stale latched bit clears immediately. The
  re-assertion that sustains the storm is a **real hardware level** from the unchanged starved
  descriptor state, not a latched bit.

---

## 4. The datum that reopened the investigation

ETHDRV-013 shipped on two lines: the v3.8.x line (driver **v2.7**, in `v3.8.5`) and the v4 line
(driver v2.14). olivluca soaked `v3.8.5` and **hit #99 again after ~3.7 days**, with driver
**v2.7** confirmed in the boot banner. `rtl8196e_tx_timeout` in v2.7 demonstrably contains the
full RX resync (`rtl8196e_ring_rx_reset` + `rtl8196e_hw_set_rx_rings`), and its entire
storm-relevant RX path is byte-identical to v2.14. **So ETHDRV-013's presence does not close
#99.**

This produced two hypotheses:

- **H1** — a TX timeout *did* fire and `tx_timeout`'s recovery ran but **failed** to stop the
  storm (the recovery is buggy or incomplete).
- **H2** — **no** TX timeout fired; the storm was reached by a path that **bypasses**
  `tx_timeout` entirely (the fix cannot catch it).

---

## 5. Method

Adversarial code review of the full RX/RUNOUT path across six dimensions (recovery correctness,
`rx_reset`/descriptor re-arm, poll/refill discipline, non-`tx_timeout` TRXRDY-cyclers, the
ISR/poll/NAPI re-enable handshake, and a v2.7↔v2.14 diff). Each candidate finding was
re-derived from the source under two independent refutation lenses (hardware/descriptor
semantics and concurrency/control-flow). The conclusions below are the survivors, re-verified
by hand against the cited lines.

---

## 6. Root mechanism — the self-sustaining handshake (code-verified)

Descriptor ownership: `RTL8196E_DESC_OWNED_BIT = 1<<0`; **set = `SWCORE_OWNED`** (the switch
owns it and may DMA an incoming frame into it), **clear = `RISC_OWNED`** (software owns it)
(`desc.h:106-109`). The switch raises `PKTHDR_DESC_RUNOUT` when it finds no `SWCORE_OWNED`
descriptor at *its* RX pointer. `PKTHDR_DESC_RUNOUT_IE_ALL` is unmasked in `CPUIIMR` by
`rtl8196e_hw_enable_irqs` (`regs.h:217`, `hw.c`).

The loop, step by step:

```
        switch RX pointer sits on a descriptor it cannot use (RISC_OWNED)
                              │  raises PKTHDR_DESC_RUNOUT (real, level)
                              ▼
  rtl8196e_isr (main.c:453)   status &= CPUIIMR; W1C status (main.c:468);
                              schedules NAPI and MASKS the line FIRST:
                              hw_disable_irqs() then __napi_schedule()  (main.c:480)
                              │
                              ▼
  rtl8196e_ring_rx_poll       entry = rx_pkthdr_ring[rx_idx]  (ring.c:483)
  (ring.c:474)                if (entry & OWNED_BIT) break;   (ring.c:492-493)
                              → the descriptor at rx_idx is SWCORE_OWNED (empty,
                                waiting for the switch), so the loop exits
                                IMMEDIATELY: work_done = 0, NOTHING re-armed,
                                rx_idx NOT advanced
                                (rx_idx is written ONLY in the re-arm path at
                                 ring.c:664 and in rx_reset at ring.c:835)
                              │
                              ▼
  rtl8196e_poll (main.c:411)  work_done (0) < budget →
                              napi_complete_done() returns true (the line was
                              masked before the schedule, so no "missed" state) →
                              W1C PKTHDR|MBUF RUNOUT + hw_enable_irqs()  (main.c:442-446)
                              → NO resync; the ring is byte-identical
                              │
                              ▼
        switch still finds no usable descriptor at its pointer → re-asserts
        PKTHDR_DESC_RUNOUT the next cycle ────────────────► (back to ISR)
```

This is a fixed point: ~100k interrupts/s, the CPU never leaves the NET_RX softirq, the timer
wheel cannot advance → soft-lockup → watchdog reboot. It matches every #99 capture, including
`napi=[rtl8196e_poll]`.

**The entry condition** is a disagreement between the switch's RX pointer and `rx_idx`. The
only thing in software that resets the switch RX pointer is a **TRXRDY cycle** (`hw_stop`
deasserts, `hw_start` asserts `SIRR` `TRXRDY`, `regs.h:76`), which rewinds it to descriptor 0.
If that happens without also forcing `rx_idx` to 0 over a fully-armed ring, the two desync and
the loop above engages.

---

## 7. Verdicts on the two hypotheses

### H1 — `tx_timeout` recovery buggy: **refuted as written**
`rtl8196e_tx_timeout` (`main.c:366-409`) is a complete, race-clean teardown+rebuild:
`netif_stop_queue` → `napi_disable` (quiesces any in-flight poll, blocks new schedule) →
`hw_disable_irqs` (so a concurrent ISR sees `status &= CPUIIMR == 0` → `IRQ_NONE`) → `hw_stop`
→ TX reclaim/reset → **`rtl8196e_ring_rx_reset`** (`ring.c:779-836`: re-arms every pkthdr+mbuf
descriptor `SWCORE_OWNED`, sets `WRAP` on the last of each, `dma_cache_wback_inv`, **`rx_idx =
0`**) → `set_tx/rx rings` → `hw_start` (asserts `TRXRDY`; switch RX pointer → 0, which is now
`SWCORE_OWNED`) → `napi_enable` → `hw_enable_irqs` → `netif_wake_queue`. This leaves
pointer(0) and `rx_idx`(0) synchronized over a fully-armed ring = the non-starved state.

The one plausible HW refutation — no trailing `wmb()` between the ownership flips in `rx_reset`
and the `TRXRDY` MMIO store — **does not hold**: the rings are **uncached KSEG1**
(`rtl8196e_alloc_uncached`) and `writel` is a volatile uncached MMIO store, so the ownership
flips are program-ordered visible before `TRXRDY` on this core without a barrier.

**Caveat (the only surviving H1 thread):** the recovery as written is *correct* but does **not
break the poll-side handshake** and does not prevent a *re-entry* (a second TX timeout, or a
fresh TRXRDY cycle from any source) from re-seeding the desync. So ETHDRV-013 is correct but
**insufficient by omission**, not internally buggy.

### H2 — trigger bypasses `tx_timeout`: **plausible, but no software trigger found**
- The poll **cannot** drain the pkthdr ring: every consumed descriptor is re-armed
  `SWCORE_OWNED` 1:1 before the cursor advances (`ring.c:~636-664`). So a poll-side pkthdr
  leak is impossible.
- The **mbuf** ring *can* be under-armed, but `MBUF_DESC_RUNOUT` has **no interrupt-enable
  define anywhere** (`regs.h` defines `MBUF_DESC_RUNOUT_IP_ALL = 1<<16` at `regs.h:222` but no
  `..._IE_…`; `hw.c rtl8196e_hw_enable_irqs` unmasks only `RX_DONE_IE_ALL | LINK_CHANGE_IE |
  PKTHDR_DESC_RUNOUT_IE_ALL`). It is therefore masked out by `status &= CPUIIMR` in the ISR and
  **never schedules NAPI** → a **silent RX stall**, never the 100k/s storm. (Real asymmetry,
  but explicitly *not* #99 — see §9.)
- The **only** TRXRDY cyclers in the tree are `hw_start`/`hw_stop`, called from `open()`,
  `stop()`, and `tx_timeout` — and **all three call `rx_reset`**. No third TRXRDY caller
  exists; `open`/`stop` bracket the whole interface.

So in the shipped control flow, the documented software entry to the desync is the `tx_timeout`
TRXRDY rewind. A *silent, non-`tx_timeout`* software entry is **unproven from the code**. The
remaining H2 candidates are **not C-level**: a silicon RX-pointer glitch, or a link-change /
bus event that resets the switch RX engine outside `open/stop/tx_timeout`. Neither is visible
as a driver code path; both would require hardware/field evidence.

---

## 8. Key conclusion → the fix must break the handshake

The storm is **self-sustaining regardless of how it was entered** (this is the strongest,
twice-verified finding). Whether olivluca's box entered via H1 (a TX timeout whose recovery did
not prevent re-entry) or H2 (a non-software pointer reset), it lands in the **same** fixed
point at §6. Patching one trigger (ETHDRV-013) cannot close a trap that has multiple doors.
**The robust fix is a poll-side, trigger-agnostic escape from the loop.**

### Proposed fix — RC1

**This is not a novel invention — it restores a safety net the vendor driver ships and our
from-scratch rewrite dropped. See §11 for the cross-check against the original Realtek SDK.**

**Idea:** the poll is the one place that runs on *every* iteration of the storm. Make it
detect that it is spinning with zero progress under a persistent RUNOUT and, at that point,
perform the same RX resync that `open()`/`tx_timeout` do — but from NAPI context — so the
switch pointer and `rx_idx` are forced back into sync. This terminates the storm no matter
which door opened it.

**Detection (precise, no false positives in normal idle):** in `rtl8196e_poll`, after
`rtl8196e_ring_rx_poll` returns, read `CPUIISR`. If `work_done == 0` **and**
`PKTHDR_DESC_RUNOUT_IP_ALL` is currently asserted, increment a consecutive-counter; otherwise
reset it. A normal zero-work poll (spurious `RX_DONE`, genuine idle) has no RUNOUT asserted, so
the counter only climbs during the actual storm.

**Action at threshold N (small, e.g. 2–3):** perform a poll-context RX resync. We are already
in NAPI context (no concurrent poll) with the eth IRQ masked (the ISR did `hw_disable_irqs`
before scheduling), so we must **not** call `napi_disable`/`napi_enable` (would deadlock).
Sequence:

```
hw_stop()                         // deassert TRXRDY → switch RX/TX engines stop
rtl8196e_ring_tx_reclaim(...)     // free in-flight TX (as tx_timeout does)
rtl8196e_ring_tx_reset(...)
rtl8196e_ring_rx_reset(...)       // re-arm all RX desc SWCORE_OWNED, rx_idx = 0
rtl8196e_hw_set_tx_ring(...)
rtl8196e_hw_set_rx_rings(...)
hw_start()                        // assert TRXRDY → switch RX pointer → 0 == rx_idx
ring->diag.rx_runout_resync++     // NEW diag counter, visible in ethtool -S / record
reset consecutive-counter
```

Then fall through to the normal `napi_complete_done` tail, which W1Cs RUNOUT and re-enables
IRQs against a **now-synced, fully-armed** ring → the switch finds a usable descriptor → no
re-assertion → loop broken in a single poll cycle.

**Diag:** add `u32 rx_runout_resync;` to `struct rtl8196e_ring_diag` (`ring.h:23`, next to
`rx_rearm_badidx`) and surface it in the ethtool stats and the watchdog record, so field
captures show the fix firing and how often.

**Lines/scope:** v4 line (this tree) `v2.14 → v2.15`, tagged **ETHDRV-015**. v3.8.x line
backport on the `v2.7` base → `v2.8`. The change is localized to `rtl8196e_poll`
(`main.c:411`), one new counter, and reuse of existing reset/HW helpers — no new HW knowledge.

**Validation plan (blocking before shipping — lesson of ETHDRV-013):** build, flash `.88`,
drive the known storm reproducer (the injector used for record-v4: forces the rx_idx/switch
desync), and confirm (a) `rx_runout_resync` increments and (b) the storm terminates within one
poll cycle (no soft-lockup, interface stays responsive). Only then create the public branches.

---

## 9. Not part of #99 (recorded to prevent a wrong turn)

The mbuf-ring under-arm (conditional re-arm at `ring.c:~650`; `rx_mbuf_no_shadow` /
`rx_rearm_badidx` paths) is a genuine asymmetry but **cannot drive the storm**: `MBUF_DESC_RUNOUT`
is never interrupt-enabled, so it yields a *silent* RX stall (low interrupt rate, no
soft-lockup), not #99. With the shipped `rx_cnt == rx_mbuf_cnt == 128`, the leak branches are
effectively dead. Pursue this only if a *separate* "quiet dead-RX, no reboot" report ever
appears — it is a different bug.

---

## 10. Open questions for the reviewer

1. **TRXRDY semantics:** does deassert/assert of `SIRR TRXRDY` rewind the switch **TX** pointer
   as well as RX? RC1 reclaims+resets TX to be safe (mirrors `tx_timeout`), accepting the drop
   of any in-flight TX SKBs on a resync — acceptable because a resync only fires in the
   otherwise-fatal storm. Confirm there is no lighter resync that resyncs RX alone without
   touching TX (e.g. is there a switch register to reset only the RX pointer?).
2. **Threshold N:** is `N=2` safe, or should we require a minimum dwell (e.g. RUNOUT asserted
   across ≥2 polls separated by an ISR) to avoid acting on a single transient? Proposed: count
   only polls where `work_done==0 && (CPUIISR & PKTHDR_DESC_RUNOUT_IP_ALL)`.
3. **Belt-and-suspenders:** keep ETHDRV-013 (one fewer door) and ETHDRV-014 (v4-line software
   TX-reclaim timer that reduces how often `tx_timeout` fires) alongside RC1? They are
   complementary; RC1 is the engine fix.
4. **Should the mbuf ring also be defensively re-armed in the resync** (it already is, via
   `rx_reset`), and should we add an `MBUF_DESC_RUNOUT_IE` + service path to convert the silent
   stall (§9) into a recoverable event while we are here?

---

## 11. Cross-check against the original Realtek SDK driver (behavioral-parity reference)

The vendor RTL8196E driver — Realtek SDK v3.4.7.3, kernel 2.6.30,
`drivers/net/rtl819x/{rtl_nic.c, rtl865xc_swNic.c}`, the lineage the Lidl stock firmware is
built from and which does **not** exhibit #99 — was reviewed to test this analysis. It both
confirms the mechanism and names the missing piece.

**Same RX architecture, same loop — confirms the storm is architecture-inherent, not a
poll-side regression we introduced.** The vendor tracks the CPU read cursor in software
(`currRxPkthdrDescIndex`, `swNic.c:506`), checks the descriptor OWN bit at that cursor exactly
as we do (`SUCCESS` iff `RISC_OWNED`), and its NAPI poll is structurally identical to ours:

```c
/* rtl_nic.c rtl865x_poll() — vendor */
work_done = interrupt_dsr_rx(cp, budget);
if (work_done < budget) { napi_complete(napi); interrupt_dsr_rx_done(); /* re-enable RX_DONE|RUNOUT */ }
```

`interrupt_dsr_rx` loops on `swNic_receive` and exits on the first "no packet"
(`rtl_nic.c:4087-4099`); its ISR treats `PKTHDR_DESC_RUNOUT` identically to `RX_DONE` — just a
stat bump (`rtl_nic.c:4926`) then schedule NAPI. **There is no poll-side escape from a
zero-work-under-RUNOUT spin.** So a cursor/switch-pointer desync would storm the vendor driver
too. Our poll is not the regression — the *absence of a recovery* is.

**The vendor never creates the desync at runtime.** It has **no `ndo_tx_timeout`**. `TRXRDY`
(`SIRR`) is asserted only at init (`rtl865x_start`, `asicCom.c`) and inside the full re-init
recovery below — never as a partial/asymmetric reset. Our `tx_timeout` was exactly such a
partial reset (the original ETHDRV-013 bug); even fixed, it remains a runtime `TRXRDY`-cycler
the vendor does not have.

**★ The vendor SHIPS the runtime recovery we dropped.** `rtl_check_swCore_tx_hang()`
(`rtl_nic.c:14885`, `CONFIG_RTL_CHECK_SWITCH_TX_HANGUP`) periodically detects a stuck switch
core — a TX-done descriptor stuck `SWCORE_OWNED` across `rtl_reinit_swCore_threshold`
consecutive checks — and calls **`rtl865x_reinitSwitchCore()`** (`rtl_nic.c:14684`):
`swNic_reInit()` (resets the cursors to 0 and re-arms the whole RX ring; cursor-reset sites
`swNic.c:1377/1387/1777`) **then** `REG32(SIRR) |= TRXRDY` (`rtl_nic.c:14706`) — a full re-init
that brings the software cursor and the hardware engine pointer back in sync **together**. The
same recovery is also driven from the PHY/link monitor (`rtl_nic.c:5382-5420`).

**Conclusion.** RC1 restores, in NAPI-friendly form, the safety net the vendor driver has and
our rewrite omitted: a runtime stuck-detector that triggers a full cursor+engine resync. Two
implementation consequences:

1. **RC1's *action* should mirror `rtl865x_reinitSwitchCore`** — a full re-init equivalent. We
   already have the body (the `open()`/`tx_timeout` reset+rearm+`TRXRDY` sequence); RC1 invokes
   it from poll context (no `napi_disable`).
2. **RC1's *detector* can be the RX-runout signal** (consecutive zero-work polls with
   `PKTHDR_DESC_RUNOUT` asserted, §8) **and/or** a periodic stuck-poll check à la the vendor.
   The RX-runout signal is the most direct trigger for the #99 storm specifically; a periodic
   check à la `rtl_check_swCore_tx_hang` is a cheap belt-and-suspenders that also covers a
   stuck-TX variant. Recommend implementing the RX-runout detector (targets #99 head-on) and
   optionally porting the vendor's periodic check as defence in depth.

---

## 12. Field recurrence on v4.0.0-rc2 — RC1 did not hold (2026-06-24)

RC1 (driver v2.15: poll-side RX-runout resync + 1 s `swcore_check` watchdog) shipped in
v4.0.0-rc2. A soaker (**frtz13**) hit #99 again after **~4.3 days** uptime
(issue #99 comment `4789134965`). The panic record is unambiguously the rc2 build —
`rtl8196e_swcore_check_timer_fn` in the pending-timers list (a v2.15-only symbol),
`napi=[rtl8196e_poll+0x0/0x1c8]` (the enlarged post-fix poll), wdt record v4 — and the
signature is the original #99 verbatim (`pc=arch_local_irq_enable / ra=handle_softirqs`,
`softirq=0xa[TIMER|NET_RX]`, `napi=rtl8196e_poll`, ~60 s lockup).

**RC1 did not prevent the lockup. Two mutually exclusive explanations remain, with
opposite fixes — and the existing record cannot distinguish them:**

- **Hyp. A — the detector never fired.** Both the poll detector (`main.c`, the
  `work_done==0 && PKTHDR_DESC_RUNOUT` gate, threshold 3 *consecutive*) and the
  `swcore_check` watchdog gate exclusively on `PKTHDR_DESC_RUNOUT`. A storm that yields
  ≥1 packet within any window of 3 polls (resetting `rx_runout_zero`), or that presents
  as an `RX_DONE` storm rather than `PKTHDR_DESC_RUNOUT`, never trips the gate. → fix =
  widen the gate.
- **Hyp. B — the resync fired and the storm continued.** `rtl8196e_hw_ring_resync()` is
  structurally complete (full `hw_stop`/`hw_start` TRXRDY cycle + `rx_idx=0` in lockstep),
  but if the TRXRDY rewind does not actually break the switch's fixed point in the field,
  the loop just becomes storm→resync→storm. → fix = strengthen the resync toward a full
  `reinitSwitchCore` (§11).

The decisive datum — `rx_runout_resync` / `rx_runout_kick` at panic — lives in RAM and is
lost on reboot; the v4 panic record never captured it. Guessing here risks a *second*
false fix on a public issue.

### Instrument first (do not touch the detector)

To answer A vs B from the field instead of by guesswork, the watchdog panic record carries
an eth #99 snapshot, pulled at panic via the `__weak` `rtl8196e_eth_panic_snapshot()`
(`drivers/net/ethernet/rtl8196e-eth/rtl8196e_main.c`, contract in
`include/linux/rtl8196e_eth_panic.h`). Record **v5** captured the recovery counters; **v6**
broadens it with switch-core / TX / ring-progress state, because the storm need not be a
pure RX runout — the vendor SDK's stuck-detector watched **TX-done**, not only RX runout, so
a broader switch-core or TX-done stall is a third possibility v5 alone could miss:

```
eth=[up=1 resync=N kick=N zero=N seen=N iisr=0x.. iimr=0x.. rxidx=N \
     rxdesc=0x.. txprod=N txcons=N txfree=N txdesc=0x.. cpuicr=0x.. sirr=0x.. rxpkts=N txpkts=N]
```

Read on the boot after a #99 lockup (and persisted by `S26panicrec`):

- `resync > 0`  ⇒ the poll resync fired and the box stormed anyway → **Hyp. B**
  (resync insufficient); strengthen the resync.
- `resync == 0` ⇒ the detector never fired → **Hyp. A**; `iisr` then names which
  interrupt bit was actually storming (RUNOUT vs RX_DONE), telling us exactly how to
  widen the gate. `zero`/`seen` = 1 or 2 (below the threshold of 3) directly shows the
  consecutive-counter being reset mid-storm.
- v6 fields settle the **third** case: `rxdesc` OWNED (SWCORE) confirms the §6 RX desync;
  `txdesc` OWNED with `txfree` low points at a stuck TX-done switch core instead;
  `rxpkts`/`txpkts` unchanged across captures show no forward progress at all; `cpuicr`/
  `sirr` show whether the DMA / switch engine was even enabled.

This is diagnosis plumbing only — **no datapath/detector behavior change** (driver bumped
to v2.17, wdt to v1.9 / record v6). The v5 pipeline was validated on the bench via a
synthetic `sysrq`-triggered panic: the eth fields are captured and self-consistent (an
idle-box capture read `iisr=0x3206` with no RUNOUT bits, `iimr=0x807e01f8` decoding to
exactly `RX_DONE_IE_ALL | LINK_CHANGE_IE | PKTHDR_DESC_RUNOUT_IE_ALL` — the live driver
mask); v6 adds more reads of the same kind through the same path. The real fix waits for
one decisive field crash.
