# RTL8196E Ethernet Driver — Performance Analysis

## Test conditions

- Hardware: Lidl Silvercrest Zigbee gateway, RTL8196E SoC, Lexra **RLX4181 @
  380 MHz** (single-core, MIPS-1 + MIPS16, big-endian, no FPU, no SIMD,
  write-back L1 cache, 16 KB I-cache, 8 KB D-cache).  32 MB DDR.  Link:
  100BASE-TX full duplex.
- Software: Linux 6.18.24 (`linux-6.18-rtl8196e/` overlay), driver
  `rtl8196e-eth` v2.4.
- Bench setup: Ubuntu 22.04 host (192.168.1.200, Gigabit NIC) with a
  short Cat 6 cable directly to the gateway (no switch / no router).
  Throughput drops by up to 60% through a consumer LAN due to buffering
  and store-and-forward latency on intermediate hops; the direct cable
  is the only setup that exposes the SoC's true ceiling.
- Measurements: iperf 2.x, 5 reps × 60 s per workload, median reported.
  OTBR + s40button quiesced before each batch.  Headline numbers come
  from the production driver (no instrumentation).  The per-phase
  decomposition below was captured with optional `ktime_get()` probes
  that live on the `feat/tx-throughput` archive branch (not on main);
  see the in-driver instrumentation section at the bottom for the
  cherry-pick procedure.

## Measured throughput

Baseline (R₀, driver v2.4 unchanged):

| Workload                    | Median (Mbit/s) | Variance (σ) |
|-----------------------------|----------------:|-------------:|
| TCP RX (host → gateway)     | 93.5            | ~0.1 %       |
| TCP TX (gateway → host)     | 69.3            | ~1.0 %       |
| UDP TX 100M (gateway → host)| 37.9            | ~0.5 %       |
| UDP storm 64-byte payload   | 1.88            | ~0.5 %       |

With Track A (kick_tx coalescing, `rtl8196e_kick_threshold = 4`,
released v3.4.1):

| Workload                    | Median (Mbit/s) | Δ vs R₀     |
|-----------------------------|----------------:|------------:|
| TCP RX (host → gateway)     | 93.4            | −0.1 %      |
| TCP TX (gateway → host)     | **70.1**        | **+1.2 %**  |
| UDP TX 100M (gateway → host)| 37.9            | 0 %         |
| UDP storm 64-byte payload   | 1.87            | −0.5 %      |

CPU is fully pegged in both directions: 0 % idle, ~77 % sys + ~22 %
sirq + ~1 % usr.

## v3.5.0 confirmation run (May 2026)

`scripts/test_rtl8196e_eth_iperf3.sh` against the v3.5.0 release kernel
(`2cc38ee`, gcc 15.2 + binutils 2.45 toolchain rebuild, slowclk rework,
HW watchdog enabled, `SOFTLOCKUP_DETECTOR_INTR_STORM` enabled). Driver
itself unchanged from Track A (v2.4 + kick_tx coalescing).

| Workload                    | Median (Mbit/s) | Δ vs Track A |
|-----------------------------|----------------:|-------------:|
| TCP RX (host → gateway)     | 94.0            | +0.6 %       |
| TCP TX (gateway → host)     | **72.8**        | **+3.9 %**   |

Stress run (300 s single-stream TCP RX): 93.3 Mbit/s sustained, 8
retransmits over 2.4 M segments (0.00 %).

Method note: this run uses iperf3 (the project's current bench tool —
see `scripts/test_rtl8196e_eth_iperf3.sh`), the Track A numbers above
were captured with iperf2. The two are within ~0.5 Mbit/s on this CPU
for steady-state TCP, so the +0.6 % / +3.9 % deltas are not an
iperf2-vs-iperf3 artefact.

Attribution: no driver code changed between v3.4.1 and v3.5.0; the TX
lift is most plausibly the gcc 8.5 → 15.2 toolchain rebuild (the v3.5.0
kernel banner already documented +0.65 % BogoMIPS and −56 KB code), with
better register allocation in the TCP send-side hot path being the
likely amplifier. **(2026-06-20: refuted — the paired history sweep below
("Release/driver history sweep") shows no measurable gcc TX gain; this
cross-session +3.9 % was session drift, not the toolchain.)** RX is already
near the per-packet cache-flush ceiling described below, so it does not see a
similar lift.

## v3.8.0 confirmation run (June 2026)

`scripts/test_rtl8196e_eth_iperf3.sh` against the v3.8.0 release kernel
(driver 2.6). Unlike the v3.5.0 run, the RX path *did* change here: the
shadow skb is now indexed by the hardware mbuf index (guarded), and the
TX submit/reclaim paths gained pool-bounds validators. This run confirms
those changes carry no throughput cost.

| Workload                    | Median (Mbit/s) | Δ vs v3.5.0 |
|-----------------------------|----------------:|------------:|
| TCP RX (host → gateway)     | 93.9            | −0.1 %      |
| TCP TX (gateway → host)     | 71.5            | −1.8 %      |

Parallel TCP RX: 94.0 (4 streams) / 93.5 (8 streams). Stress run (300 s
single-stream TCP RX): 93.5 Mbit/s sustained, 19 retransmits over 2.44 M
segments (0.00 %). Interface counters across the whole suite: rx_errors
0, rx_dropped 0, tx_errors 0, tx_dropped 0.

The TX delta vs the v3.5.0 confirmation (72.8) is within this CPU's
run-to-run spread (TX has ranged 69.3–72.8 across sessions); the
validators add only a couple of bounds checks per descriptor. No
regression: RX holds line-rate, TX stays at the ~71 Mbit/s asymptote
described below.

## v3.9.0 / kernel 6.18.35 confirmation run (June 2026)

`scripts/test_rtl8196e_eth_iperf3.sh` against the kernel bumped from
6.18.24 to 6.18.35 (the SysRq dispatch series we submitted is now mainline,
so the three provisional patches were dropped; no `arch/mips` change between
the two point releases). Driver unchanged (2.6, identical to v3.8.0). The
in-kernel UART↔TCP bridge was disabled (`enable=0`) for the bench, as is
standard for eth measurements. Single direct Cat-6 cable, host 192.168.1.200.

| Workload                    | Median (Mbit/s) | Δ vs v3.8.0 |
|-----------------------------|----------------:|------------:|
| TCP RX (host → gateway)     | 93.8            | −0.1 %      |
| TCP TX (gateway → host)     | 69.9            | −2.2 %      |

Parallel TCP RX: 94.0 (4 streams) / 93.9 (8 streams). Stress run (300 s
single-stream TCP RX): 93.7 Mbit/s sustained, 9 retransmits over 2.44 M
segments (0.00 %), 1 InErr. Interface counters across the whole suite:
rx_errors 0, rx_dropped 0, tx_errors 0, tx_dropped 0; TCP RetransSegs
0.0000 %.

UDP RX (host → gateway, offered rate vs delivered): 10M → 10.0 Mbit/s
0 % loss; 50M → 41.7 Mbit/s 17 % loss; 100M → 27.5 Mbit/s 72 % loss.
The gateway saturates absorbing UDP into the socket at ~42 Mbit/s, above
which `RcvbufErrors` climb — the receiver-side ceiling, unchanged from
prior runs and not a NIC drop (eth0 rx_dropped stays 0).

No regression. RX holds line-rate; the TX 69.9 sits at the low end of this
CPU's documented run-to-run spread (TX has ranged 69.3–72.8 across sessions
with no driver change), so the −2.2 % vs the v3.8.0 confirmation is variance,
not a 6.18.35 cost — consistent with the script's own embedded v3.4.1
baseline (RX 93.7 → 93.8, TX 70.0 → 69.9).

## Driver v2.9 gate run (June 2026, audit-fix batch)

`scripts/test_rtl8196e_eth_iperf3.sh`, kernel 6.18.35 + the full June
audit batch (8250 v1.4, clocksource v1.2 timer_of, gpio v1.2, wdt v1.6).
Driver 2.8 → 2.9: ETHDRV-008 (ring-array cache flush before KSEG1
aliasing), ETHDRV-009 (stop() napi_disable-first ordering), ETHDRV-010
(probe IRQ quiesce), ETHDRV-012 (ndo_change_mtu, F2 pattern) — all
probe/teardown-path changes, zero hot-path edits. Bridge armed but idle
(no TCP client) in both runs; same-day baseline captured under
identical conditions.

| Workload                    | Same-day baseline (v2.8) | v2.9 |
|-----------------------------|-------------------------:|-----:|
| TCP RX (host → gateway)     | 93.9                     | 93.9 |
| TCP TX (gateway → host)     | 68.2                     | 73.2 |

Parallel TCP RX: 94.0 (4 streams) / 93.8 (8 streams), both identical to
baseline. Stress (300 s TCP RX): 93.9 sustained vs 93.6 baseline.
RetransSegs 0.0000 % in both directions. UDP RX: 10M → 0 % loss,
50M → 43.7 delivered (13 % loss), 100M → 31.8 delivered (68 % loss),
bidir 50M+50M → clean at the 8.5 effective ceiling — the usual
rcvbuf-bound receiver profile (eth0 rx_dropped 0).

No regression; the TX delta (+5.0) is the documented run-to-run layout
spread (69.3–72.8 historically; the 68.2 baseline run sat at the low
edge), not a v2.9 effect. Functional checks the same session: down/up
cycle with traffic after (ETHDRV-009), `ip link set mtu` refused with
EBUSY while UP / accepted while down (ETHDRV-012), nRST RSTACK proof
after an eth flap (mux ownership intact).

## Driver v2.10 gate run (June 2026, scaffolding removal)

Same session as v2.9. Driver 2.9 → 2.10: ETH-S02 (debug scaffolding
removed: dbg_timer, tx_debug_once, tx_dbg_* ethtool slots, dbg_irqs,
force_trap, rtl8196e_debug param, six orphaned ring accessors —
ETHDRV-011 closed by deletion), S04 (dead defines, Kconfig help),
S06 (hw.base member, (void)hw casts), S07 (tx_submit flags folded into
the ring layer). Net −~190 lines; the only hot-path effect is the
*removal* of two always-tested branches (xmit first-packet capture,
ISR debug print).

| Workload                    | v2.9 | v2.10 |
|-----------------------------|-----:|------:|
| TCP RX (host → gateway)     | 93.9 | 93.9  |
| TCP TX (gateway → host)     | 73.2 | 70.2  |

Parallel TCP RX: 94.0 / 93.9. Stress (300 s): **94.1** sustained (best
recorded). UDP profile unchanged (10M 0 % / 50M 16 % / 100M 68 %).
Two confirmation single-stream TX runs: 69.9, 70.2 — v2.10 sits
mid-spread where v2.9 measured at the high edge (documented layout
spread 69.3–72.8 with no driver change); deletion of dead branches has
no mechanism for a real cost, classified variance like the v3.9.0
−2.2 % case. ethtool stat renumbering verified on-target.

## Driver v2.11 gate run (June 2026, bring-up hoisted to probe)

Same session. Driver 2.10 → 2.11: ETH-S03 — the one-time SoC bring-up
(pinmux/0x44 board state, switch-clock toggle, MEMCR, FULL_RST, L2
clear; ~650 ms of sleeps) runs once at probe; `ndo_open` keeps only
per-open programming and measures **~30 ms** (was >1 s).

| Workload                    | v2.10 | v2.11 |
|-----------------------------|------:|------:|
| TCP RX (host → gateway)     | 93.9  | 93.9  |
| TCP TX (gateway → host)     | 70.2  | 69.7  |

Parallel TCP RX: 94.0 / 93.8. Stress (300 s): 94.0 sustained. UDP
profile unchanged (10M 0 % / 50M 14 % / 100M 67 %). TX within the
layout spread. Functional: down/up flap followed by an nRST RSTACK
proof — pad muxes stay correct without the per-open 0x44 re-write.

## Driver v2.12 gate run (June 2026, DT resource model)

Same session. Driver 2.11 → 2.12: ETH-S01 resource-claim variant — the
three register windows are declared in the DT, claimed at probe and
verified against the compile-time KSEG1 constants (probe fails on
mismatch); the hot-path accessors are unchanged by design (see the
rationale in `rtl8196e_regs.h`). Zero hot-path edits.

| Workload                    | v2.11 | v2.12 |
|-----------------------------|------:|------:|
| TCP RX (host → gateway)     | 93.9  | 93.9  |
| TCP TX (gateway → host)     | 69.7  | 71.3  |

Parallel TCP RX: 94.0 / 93.9. Stress (300 s): 94.1 sustained. UDP
profile unchanged. TX wobble within the layout spread, as expected for
a probe-only change.

## Driver v2.13 gate run (June 2026, BQL)

Same session. Driver 2.12 → 2.13: ETH-S05 — BQL on the single TX queue
(sent/completed/reset hooks; both sides account `skb->len`). Purpose is
TX latency under load (bufferbloat control), not throughput; the gate
checks it costs nothing.

**Why it is worth keeping (the case the gate cannot show).** The TX ring
is 128 descriptors. Unthrottled, the stack can fill it: 128 × ~1514 B
≈ 194 KB of frames committed FIFO below the qdisc, which at 100 Mbit/s
(~12.5 MB/s) is **~15 ms of dumb buffering**. BQL caps the *bytes in
flight* instead — measured `byte_queue_limits/limit` converges to
**~2.5 KB** (< 2 full frames ≈ **~0.2 ms**) under the iperf load, so the
worst-case ring-induced latency drops ~75× for a throughput cost that is
≤1 % and below the measurement floor (see the A/B below). This matters
*here specifically* because the box is a Zigbee/Thread coordinator: the
in-kernel UART↔TCP bridge (TCP:8888) carries EZSP/CPC/Spinel control
frames over the same eth0 as any bulk transfer (log pull, OTA, dev
iperf), and ASH/CPC retransmit timers and OpenThread MLE/keepalive
timing do not tolerate ~15 ms of head-of-line jitter — that jitter is
what spawns spurious retransmits and, at the extreme, dropped
CPC/Thread sessions. BQL is also the *enabler* for the qdisc: a qdisc
(`pfifo_fast` today, a future `tc … fq_codel`) can only schedule
packets still in the qdisc — once they escape into the deep ring they
are FIFO-committed and unreorderable, so without BQL even fq_codel is
short-circuited. It is, besides, the standard hygiene expected of any
modern soft-reclaim Linux NIC driver, which is the stated goal of this
rewrite.

| Workload                    | v2.12 | v2.13 |
|-----------------------------|------:|------:|
| TCP RX (host → gateway)     | 93.9  | 94.0  |
| TCP TX (gateway → host)     | 71.3  | 69.5  |

Parallel TCP RX: 93.8 / 93.9. Stress (300 s): 94.1 sustained. UDP
profile unchanged. Single-stream RetransSegs 0. TX within the layout
spread. `byte_queue_limits/limit` observed converged (~2.5 KB) after
the suite — BQL is active and bounding the queue.

### TX median A/B, v2.9 vs v2.13 (5 reps each)

The single-run gate figures above understate the run-to-run spread, so
the BQL TX cost was isolated with a 5-rep TX-only median (gateway → host
reverse, 20 s, 2 s warmup omitted, OTBR quiesced, same final kernel
flashed for each side):

| Driver | runs (Mbit/s)              | median | range      |
|--------|---------------------------|-------:|-----------:|
| v2.9   | 70.5 70.0 72.1 70.8 69.6  |  70.5  | 69.6–72.1  |
| v2.13  | 70.3 71.9 69.8 68.8 68.7  |  69.8  | 68.7–71.9  |

Median Δ = **0.7 Mbit/s (~1 %)**, v2.13 lower — but the ranges overlap
almost entirely (69.6–71.9 common) and each median sits inside the
other's range, so at n=5 it is **not distinguishable from layout/I-cache
noise** and is below the project's 1 Mbit/s "investigate" threshold.
There is a faint consistent lean (v2.13's two lowest, 68.7/68.8, fall
under v2.9's worst, 69.6), the order of magnitude expected from BQL's
per-packet `netdev_sent_queue`/`netdev_completed_queue` atomics on this
in-order CPU; it cannot be attributed cleanly because the v2.9→v2.13
span also *removed* hot-path branches (v2.10), so the measured net is
the sum of all changes. Note the v2.9 gate single-run (73.2) was a
high outlier — well above its own 5-rep median of 70.5. BQL stays: its
benefit is TX latency/bufferbloat control, and any throughput cost is
≤1 % and buried in noise.

## Driver v2.14 gate run (June 2026, #99 tx_timeout fix + TX-reclaim timer)

`scripts/test_rtl8196e_eth_iperf3.sh` against the v4.0.0-rc1 candidate
(`6.18.35-rtl8196e-v4.0.0-rc1`), OTBR stopped. Driver 2.13 → 2.14 carries
two robustness changes plus their perf follow-up:

- **ETHDRV-013** — `tx_timeout` now resets *both* rings, not just TX. Its
  `hw_stop()`/`hw_start()` rewinds the switch RX engine to descriptor 0, so a
  TX-only recovery desynced `rx_idx` and storms `PKTHDR_DESC_RUNOUT` — the #99
  soft-lockup. This lives entirely in the recovery path (runs only after a
  stall), so it has no steady-state throughput cost by construction.
- **ETHDRV-014** — a software TX-reclaim timer (`RTL8196E_TX_RECLAIM_MS`)
  breaks the rare no-RX TX stall where reclaim would otherwise wait for an RX
  IRQ that never comes. The timer is armed from the TX hot path whenever the
  queue is found stopped, which under load is most packets.

The reclaim timer is the only v2.14 change that touches the hot path. An
unguarded `mod_timer()` per packet cost **~5 % of TX** (rc0 regressed to
**67.6** Mbit/s, RX unaffected); guarding the arm with `timer_pending()`
(commit `b62ec01`) restores it — the timer still fires within one
`RTL8196E_TX_RECLAIM_MS` window but is free once armed (rc1: **70.8**
Mbit/s). The net v2.13 → v2.14 hot path is therefore throughput-neutral.

| Workload                    | v2.13 | v2.14 |
|-----------------------------|------:|------:|
| TCP RX (host → gateway)     | 94.0  | 93.6  |
| TCP TX (gateway → host)     | 69.5  | 69.1  |

Parallel TCP RX: 94.0 (4 streams) / 93.8 (8 streams). Stress (300 s
single-stream RX): 94.0 sustained, 11 retransmits over 2.44 M segments
(0.00 %), 1 InErr. UDP RX: 10M → 0 % loss, 50M → 44.7 delivered (11 % loss),
100M → 31.3 delivered (68 % loss); bidir 50M+50M → host→gw 20.2 (60 % loss),
gw→host 8.40 (0 %) — the usual rcvbuf-bound receiver profile. Interface
counters across the whole suite: rx_errors 0, rx_dropped 0, tx_errors 0,
tx_dropped 0; TCP RetransSegs 0.0000 %.

### TX dispersion, v2.14 (5 reps)

The suite's single-run TX (69.1) landed at the low edge of this CPU's
documented spread, so the figure was characterised with a 5-rep TX-only
sweep (gateway → host reverse, 30 s, OTBR stopped):

| Driver | runs (Mbit/s)              | median | range      |
|--------|---------------------------|-------:|-----------:|
| v2.14  | 69.1 69.9 70.3 71.3 72.3  |  70.3  | 69.1–72.3  |

Median 70.3, range 69.1–72.3 — squarely inside the documented run-to-run
spread (69.3–72.8 across sessions with no driver change). The suite's 69.1
single-run was the low edge, not a regression: the #99 recovery fix is
invisible to steady-state throughput and the reclaim-timer arm is neutralised
by the `timer_pending()` guard.

### rc0 vs rc1 measured A/B — the guard's real-world effect (2026-06-17)

The guard's effect was characterised directly by benching the two shipped
release images head-to-head on the same box and session (5-rep TX, OTBR
stopped, direct Cat-6; the two are distinguished by `uname` — `…-rc0` vs
`…-rc1`):

| Image                  | runs (Mbit/s)              | median | range      |
|------------------------|----------------------------|-------:|-----------:|
| v4.0.0-rc0 (unguarded) | 67.0 67.1 67.6 67.9 68.7   |  67.6  | 67.0–68.7  |
| v4.0.0-rc1 (guarded)   | 68.0 69.0 69.0 69.2 69.6   |  69.0  | 68.0–69.6  |

rc0 reproduces its documented ≈67.6 to the decimal — the unguarded per-packet
`mod_timer()` regression is real and present in the shipped rc0 image. The
guard recovers **+1.4 Mbit/s** (rc0 67.6 → rc1 69.0), confirming it works: the
medians are cleanly separated, though the tails overlap (68.0–68.7) because the
benefit is small. The gain was smaller this session than the +3.2 originally
documented (rc0 67.6 → rc1 70.8): rc1 here sat at the low edge of its 69.1–72.3
band while rc0 matched its baseline, so the guard's *measured* benefit varies
run-to-run — it depends on how often the TX queue stops and re-arms under the
offered load — but it is always ≥ 0 and rc1 ≥ rc0.

This is a 6.18-internal effect. For the *kernel-version* TX gain stacked on top
of it (6.18 → 7.1, driver held constant at v2.14), see the A/B in the 7.1
line's `PERFORMANCE.md` (`files-7.1/…`, branch `exp/kernel-7.1`): 7.1 ≈ 72.1, a
further ~+3 over rc1. Same-box hierarchy: rc0 67.6 → (guard) rc1 69.0 →
(kernel) 7.1 72.1.

## Driver v2.15 gate run (June 2026, #99 trigger-agnostic poll-side resync)

`scripts/test_rtl8196e_eth_iperf3.sh` against the v4.0.0-rc2 candidate
(`6.18.35-rtl8196e-v4.0.0-rc2`), OTBR stopped. Driver 2.14 → 2.15 adds
**ETHDRV-015** — the field fix for issue #99 after ETHDRV-013 (the v2.7
`tx_timeout` RX-resync) proved insufficient (olivluca re-hung after ~3.7 d
with that fix already present). Full root-cause in this directory's
`issue99.md`; in short the RUNOUT storm is self-sustaining and
trigger-agnostic, so the fix moves out of the recovery path and into the
poll itself:

- a **poll-side detector** — three consecutive zero-work polls entered under
  `PKTHDR_DESC_RUNOUT` trigger a full `rtl8196e_hw_ring_resync()` from poll
  context (no `napi_disable`), breaking the handshake whatever opened it;
- a **periodic `swcore_check_timer`** (~1 s) that re-schedules NAPI if RUNOUT
  persists — restoring the safety net the original Realtek SDK 2.6.30 driver
  carried (`rtl_check_swCore_tx_hang` → `rtl865x_reinitSwitchCore`) and that
  this rewrite had dropped.

Both sit off the steady-state hot path by construction: the detector is a
single conditional MMIO read taken **only** on a zero-work poll, the timer
reads CPUIISR once a second. Two diagnostic `ethtool -S` counters were added
(`rtl8196e_rx_runout_resync`, `rtl8196e_rx_runout_kick`).

| Workload                    | v2.14 (rc1) | v2.15 (rc2) |
|-----------------------------|------------:|------------:|
| TCP RX (host → gateway)     | 93.6        | 93.2        |
| TCP TX (gateway → host)     | 70.3        | 70.0        |

(v2.15 RX is a single clean gate run; v2.15 TX is the canonical-rig
inter-session median from the campaign below. RX on this SoC is
line-rate/DMA-bound and rig-insensitive — see the TX/RX asymmetry section —
so the 0.4 dip is noise.) Both new counters read `0` after the suite,
rx/tx errors 0, rx/tx_dropped 0; OTBR up, no `tx_timeout` / RUNOUT /
soft-lockup over the run.

### 013/014 cost A/B — a short-run signal, refuted at steady state (2026-06-19)

A question worth settling directly: do the two v2.14 robustness changes
(ETHDRV-013, the `tx_timeout` dual-ring reset; ETHDRV-014, the software
TX-reclaim timer) cost anything once shipped? Measured back-to-back on the
same box and session, OTBR stopped, 5-rep medians. These were short 6 s runs
on a slightly slower bench host, so the absolute numbers run ~1–2 Mbit/s low
— but the **A/B delta at identical methodology is the clean signal**:

| Build                              | RX (host→gw)     | TX (gw→host)     |
|------------------------------------|------------------|------------------|
| with 013/014 (v2.15 as shipped)    | 92.9 (92.8–93.6) | 67.9 (67.7–67.9) |
| without 013/014 (015 kept)         | 93.2 (92.5–93.6) | 69.3 (69.0–69.7) |
| **Δ**                              | ~0 (noise)       | **+1.4 (~2 %)**  |

At this 6 s methodology **013/014 measured ~1.4 Mbit/s (~2 %) on TX, zero on
RX** — the two TX clusters did not overlap (67.7–67.9 vs 69.0–69.7).
Attribution within the A/B:

- **015 is not the cause** — it is present in *both* arms, confirming the new
  #99 engine fix is genuinely off the hot path.
- **013 is off-datapath** (runs only on `tx_timeout`) → ~0 cost.
- **014** is the only hot-path actor: even guarded by `timer_pending()`, during
  TX it arms a reclaim timer, and at 6 s (cwnd not ramped, the queue spends a
  large fraction of the run XOFF-stopped → the timer arms often) that churn is
  visible.

**This ~2 % does NOT hold at steady state — it is a short-run artifact.** It
was checked directly (2026-06-20): a build with 014 relaxed **4 ms → 50 ms**,
benched with the *same* 15-run / 30 s inter-session protocol as the campaign
below, gave median **69.5**, mean 69.21, range 68.1–69.9 (sd 0.64) — i.e. **no
recovery**; if anything marginally *below* the 4 ms median (~70), and squarely
inside the inter-session noise band. At a realistic 30 s transfer the queue is
rarely XOFF-stopped, so the timer almost never re-arms and 4 ms vs 50 ms is
indistinguishable; the ~3 Mbit/s inter-session spread dwarfs the effect. (The
two builds were on different sessions, so they cannot be *ranked* at the
sub-Mbit level, but the absence of any gain at 50 ms is unambiguous.)

Conclusion: **014's 4 ms timer is throughput-neutral at realistic transfer
sizes** — the 6 s A/B over-attributed a methodology artifact to it. 4 ms is
kept for rc2: it gives the tightest no-RX TX-stall recovery (well under the
10 s netdev watchdog, important for Zigbee/Thread control-traffic latency) at
no measurable steady-state throughput cost. Relaxing it buys nothing and only
lengthens that recovery, so there is no reason to.

### Inter-session TX campaign on the canonical rig (2026-06-20)

The A/B above used short runs on a slower host for a clean *relative* signal;
the *absolute* rc2 TX was then characterised properly on the canonical bench
rig (host 192.168.1.200, direct Cat-6, OTBR stopped, gw running clean
v4.0.0-rc2), inter-session: fresh connection, 30 s each, spaced.

| Campaign        | runs (Mbit/s)                                     | median | spread / range      | sd   |
|-----------------|---------------------------------------------------|-------:|---------------------:|-----:|
| N=5             | 71.9 69.3 70.7 72.3 70.6                           |  70.7  | 3.0 (69.3–72.3)      | 1.19 |
| N=10            | 70.1 71.8 69.9 71.3 69.5 69.6 69.5 69.7 69.5 69.4 |  69.7  | 2.4 (69.4–71.8)      | 0.84 |
| **N=15 (both)** | —                                                 |  ~70   | **3.0 (69.3–72.3)**  | —    |

N=15 envelope **69.3–72.3** = exactly the documented run-to-run spread
(69.3–72.8 across sessions with no driver change), median ~70. **v2.15 TX is
on baseline; ETHDRV-015 is throughput-neutral.** The N=10 run also shows the
platform's *settling* behaviour cleanly — the first 4 runs span 69.9–71.8,
the last 6 converge to 69.4–69.7 — which is why a warm back-to-back burst
reads ultra-tight (0.2–0.7 intra-session) while a cold spaced campaign
reopens the ~3 Mbit/s band. Methodology, not code: intra-session bursts are
not comparable to the inter-session baseline.

## Standardized release bench — v4.0.0-rc2 (2026-06-20)

First run of the new per-release suite `scripts/bench_release_iperf3.sh`
(`6.18.35-rtl8196e-v4.0.0-rc2 #8`). The suite is the reproducible, portable
successor to the ad-hoc campaigns above: **3× TCP RX, 10× TCP TX, 1× 300 s
stress, 3× UDP TX (`-b 0`), 3× UDP RX (`-b 100M`)**, medians reported. It
uses **no ethtool** (counters from `/proc/net/dev` + `/proc/net/snmp`, split
into a TCP window that must be 0 and a UDP-flood window where line-rate ring
drops are expected), a configurable gateway iperf3 path (`IPERF3_BIN`, so it
runs against stock Lidl firmware), and a strict inter-session protocol —
**each rep restarts a fresh gateway iperf3 server + fresh client**, spaced by
`GAP` (10 s here). Rig: host 192.168.1.200 direct Cat-6 on `enp2s0`, OTBR
(`S70otbr`) quiesced for the run and restarted after.

| Workload | Reps | Median (Mbit/s) | Spread / loss |
|---|:--:|--:|---|
| TCP RX (host → gateway)          | 3  | 93.9 | range 93.4–93.9 |
| **TCP TX (gateway → host)**      | 10 | **69.0** | spread 1.4, sd 0.47, range 68.7–70.1 |
| TCP stress (host → gw, 300 s)    | 1  | 93.9 | retrans 0.0000% |
| UDP TX (gateway → host, `-b 0`)  | 3  | 31.7 | loss 0.0% |
| UDP RX (host → gateway, `-b 100M`)| 3  | 31.3 | loss 67.0% |

TCP-phase counters: rx_errs / rx_drop / tx_errs / tx_drop **all +0**;
RetransSegs **+0 of 1,917,714** (0.0000%). UDP-flood window: rx_drop +0.
**Verdict: PASS.**

The 10 TX reps were 68.7 70.1 69.0 68.8 69.0 69.0 69.9 68.8 69.1 68.7 —
spread **1.4** (sd 0.47), a settled-low session sitting at the floor of the
documented 69.3–72.8 band. Note the within-bench TX spread is *drift-bounded*
(the box holds one thermal/clock state across the ~18-min run), so a single
suite run reads tighter (~1–1.5) than the full cross-session ~3 Mbit/s band;
the wide band only appears across separate boots/sessions. The new UDP
figures (TX ~31.7, RX ~31.3) are the iperf3 baselines for this tool and do
not compare to the older iperf2 UDP numbers (37.9 / 42) — more per-packet
overhead in iperf3, and `-b 0` is the cleanest TX-ceiling probe (it beat a
bounded `-b 100M`, 31.5 vs 27.4, on this CPU).

## Release/driver history sweep — drift-cancelled (2026-06-20)

`scripts/bench_history_sweep.sh --preset perf-boundaries --rounds 3`: every
release image is replayed on **one box in one session**, in **randomized
interleaved rounds**, and each build's TX is **normalized to rc2 measured in the
same round** so the ~3 Mbit/s session drift cancels (the ±95 % CI is on the
per-round ratio). 21 points, ~64 min, all booted, box restored to rc2. This is
the objective cross-version comparison the single-session sections above cannot
give. The preset is the only releases where eth driver code, kernel minor, or
gcc actually change (detected from git); perf-identical releases are skipped.

| Build (6.18 line) | kernel | TX median | TX vs rc2 (±95 % CI) | distinguishable? |
|---|---|---:|---:|---|
| v3.0.0 | 6.18.24 | 68.6 | 1.004× ±0.015 | no |
| v3.4.0 | 6.18.24 | 69.4 | 1.018× ±0.026 | no |
| **v3.4.1** | 6.18.24 | 70.3 | **1.035× ±0.018** | **yes — +3.5 %** |
| v3.5.0 | 6.18.24 | 69.0 | 1.017× ±0.048 | no |
| v3.8.0 | 6.18.24 | 68.5 | 1.009× ±0.044 | no |
| v3.9.0 | 6.18.35 | 68.8 | 1.007× ±0.019 | no |
| rc2 | 6.18.35 | 68.2 | 1.000× (ref) | — |

**Findings:**
- **TX is flat to ~1-2 % across the whole 6.18 history**, with a single nominal
  peak: **v3.4.1** (Track A `kick_tx` coalescing) at **+3.5 %** over rc2 — the
  only build whose CI excludes 1.000, and only barely at n=3. rc2 sits at the
  bottom of an otherwise flat cluster (v3.5.0…rc2 all ~1.00–1.02, mutually
  indistinguishable).
- **The "regression" below the v3.4.1 peak is NOT attributable to BQL/014.** A
  direct paired A/B (2026-06-20, 5 rounds, rc2 vs a build with **both** BQL and
  the 4 ms reclaim timer disabled) recovered only **1.012× ±0.018** — CI
  [0.994, 1.030] **includes 1.000, i.e. not significant**. Removing the prime
  suspects does *not* close the gap to v3.4.1. Likeliest reading: v3.4.1's
  +3.5 % is partly an n=3 high read, and TX across the 6.18 line is flat within
  ~2-3 % measurement noise — there is **no robustly-attributable post-v3.4.1
  regression**. (This also confirms BQL + the 4 ms timer are ≈free at realistic
  transfer sizes; the earlier 6 s 013/014 A/B's ~2 % was a short-run artifact —
  see the v2.15 section.)
- **gcc 8.5 → 15.2 gave no measurable TX gain.** The `v3.4.1 → v3.5.0`
  transition changes *only* the toolchain (driver code identical) and reads
  1.035× → 1.017× — flat-to-slightly-lower, CIs overlapping. The "+3.9 % from
  the toolchain" attributed in the v3.5.0 confirmation section above was a
  **cross-session drift artifact**, not a real effect — exactly the trap this
  paired design removes.
- **The kernel minor 6.18.24 → 6.18.35 gave no measurable TX effect** either:
  `v3.8.0 → v3.9.0` (driver code identical) reads 1.009× → 1.007×.

Caveat: at 3 rounds the CIs are wide (±0.015–0.048); v3.4.1's signal is clear,
but separating v3.5.0/v3.8.0 at the sub-percent level would need more rounds. RX
held line-rate (93.2–94.1) on every build. Raw data:
`test_results_history_sweep_*/sweep.tsv`.

## Standardized release bench — v4.0.0-rc4 / driver v2.20 (2026-06-30)

`scripts/bench_release_iperf3.sh` against `6.18.35-rtl8196e-v4.0.0-rc4 #12`
(driver v2.20: switch-core PHY-interface watchdog + comment genericization +
debug-injector removal — the watchdog is a 1 s cold-path timer, and the removed
injectors were `#ifdef CONFIG_RTL8196E_ETH_DEBUG` code that never compiled, so
the RX/TX hot path is byte-identical to rc4). Same protocol as the rc2 run
above. Rig: host 192.168.1.200 direct Cat-6 on `enp2s0`, OTBR quiesced.

| Workload | Reps | Median (Mbit/s) | Spread / loss |
|---|:--:|--:|---|
| TCP RX (host → gateway)           | 3  | 94.0 | range 93.8–94.0 |
| **TCP TX (gateway → host)**       | 10 | **67.0** | spread 1.2, sd 0.38, range 66.6–67.8 |
| TCP stress (host → gw, 300 s)     | 1  | 93.9 | retrans 0.0000% |
| UDP TX (gateway → host, `-b 0`)   | 3  | 32.0 | loss 0.0% |
| UDP RX (host → gateway, `-b 100M`)| 3  | 31.8 | loss 67.0% |

TCP-phase counters: rx_errs / rx_drop / tx_errs / tx_drop **all +0**;
RetransSegs **+0 of 1,867,003** (0.0000%). UDP-flood window: rx_drop +0.
**Verdict: PASS.**

TX sat at **67.0** (10 reps 66.6–67.8, sd 0.38) — ~2 Mbit/s under the rc2
suite's 69.0 and just below the documented 69.3–72.8 band, but a *settled-low
session*, not a regression. The driver change cannot move TX: the hot-path
codegen is byte-identical to rc4, and the new watchdog runs once per second from
a timer, never on the datapath. TX is CPU-bound (gw 0 % idle, confirmed). The
same day, a clean reboot to a cold-boot switch state (vs the
post-`FullAndSemiReset` state the suite happened to run on, after a PHY-watchdog
bench) reproduced the figure — 5 cold-boot TX reps 66.9–67.2, median **67.1** —
so the number is neither a deep-reset artefact nor driver-introduced; it is this
box/session's position in the variance band the rest of this doc characterises
(same-day lows of 68.2 at v2.8; the +3.9 % v3.5.0 "toolchain" lift since refuted
as session drift). RX holds line-rate, retrans 0. No action.

## `xmit_stopped` hint measurement — driver v2.20 (2026-07-01, `optim_tx` branch)

Two sites in the TX path arm the software TX-reclaim timer when the queue is
already stopped: `rtl8196e_start_xmit()` (after submit) and `rtl8196e_poll()`
(after reclaim), both hinted `unlikely(netif_xmit_stopped(...))`. Both predate
BQL (v2.13), whose converged byte limit is documented above as **~2.5 KB**
under sustained TCP TX — under 2 full frames, which raised the question of
whether "queue stopped" had become the *common* case on this exact workload,
making `unlikely()` stale. Rather than infer from the 2.5 KB figure alone
(itself measured on a different run and BQL's limit is adaptive), two ethtool
counters were added (`tx_xoff_seen_xmit`, `tx_xoff_seen_poll`, feat commit
`887d696`) and read back after a real transfer.

Rig: `iperf3 -c <gw> -R -t 30` (gateway → host, 192.168.1.200 direct Cat-6 on
`enp2s0`), OTBR fully stopped (`S70otbr stop` + `killall keepalive otbr-agent
otbr-monitor`, verified via `ps`), fresh `6.18.35-rtl8196e-v4.0.0-rc4 #16`.
Result: 238 MBytes / 66.6 Mbit/s, 0 retrans.

| Counter               | Before | After  | Delta | / tx_packets (173,582) |
|------------------------|-------:|-------:|------:|------------------------:|
| `tx_xoff_seen_xmit`    |      4 |     75 |    71 | **0.0409 %** |
| `tx_xoff_seen_poll`    |      0 |     10 |    10 | **0.0058 %** |
| `tx_ring_full`         |      — |      — |     0 | driver ring never saturated; all XOFF events were BQL byte-limit, not ring-full |

**Verdict: `unlikely()` stays. No code change.** The queue is observed stopped
in roughly 1 packet in 2,400 (`start_xmit`) and 1 in 17,000 (`poll`) — nowhere
near the >50 % line that would justify flipping the hint, and nowhere near
what the raw ~2.5 KB BQL figure alone might have suggested. BQL's byte-limit
XOFF is evidently a brief, self-clearing transient (the queue reopens well
before the next packet in the overwhelming majority of cases), not a
steady-state condition — consistent with BQL's own purpose (bounding
bufferbloat latency, not throttling steady throughput). The two counters are
kept permanently (matching this driver's convention for structural-condition
observability counters, e.g. `poll_budget_hit`/`rx_stall_run`).

## Standardized release bench — v4.0.0 candidate / driver v2.23 / kernel 6.18.38 (2026-07-17)

`6.18.38-rtl8196e-v4.0.0-rc5 #1`, driver **v2.23** (the independent-audit
hardening pass: atomic `tx_timeout`, IRQ-safe NAPI kicks, switch-core recovery
hold-down with bounded retries, cache-line pkthdr slots, safe-default RX
checksum, 64-bit stats). Host `Gigabyte` direct via `enp2s0`, radio quiesced,
`iperf3` 3.18 both ends. Two tools: `scripts/bench_release_iperf3.sh` (fresh
server + client per rep, **median** reported) for the headline TCP/UDP, and
`scripts/test_rtl8196e_eth_iperf3.sh` for the parallel-stream and full UDP
breakdown.

**Release bench (medians):**

| Workload | Reps | Median (Mbit/s) | Spread / loss |
|---|:--:|--:|---|
| TCP RX (host→gw) | 3 | **90.4** | 89.9–90.5 |
| TCP TX (gw→host) | 10 | **71.5** | range 70.0–72.7, σ 0.78 |
| TCP stress (host→gw, 300 s) | 1 | 90.1 | retrans 0.0000 % |
| UDP TX (gw→host, `-b 0`) | 3 | 32.9 | 0 % loss |
| UDP RX (host→gw, `-b 100M`) | 3 | 34.8 | 64 % loss |

**Full suite (single runs) — parallel + UDP:**

| Workload | Mbit/s | Retrans / loss |
|---|--:|---|
| TCP RX 1-stream | 90.0 | 0.00 % |
| TCP RX 4-stream | 93.9 | 0.29 % |
| TCP RX 8-stream | 88.7 | 0.12 % |
| TCP stress 300 s | 91.5 | 0.00 % |
| UDP RX 10M / 50M / 100M | 10.0 / 47.3 / 34.9 | 0 % / 5.3 % / 64 % |
| UDP bidir 50M (host→gw / gw→host) | 21.2 / 9.26 | 58 % / 0 % |

Interface over the whole suite: RX +3.72 M pkts, **errors 0**, drop 304; TX
+302 k, errors 0, drop 0. **TCP RetransSegs +0 (0.0000 %)**. UDP flood loss is
`RcvbufErrors` (receiver socket-buffer overflow, 44.8 % aggregate at the offered
flood rates) — expected, not a driver drop. TX kicks: cold 73.0 %,
**threshold 24.6 %** (coalescing batch path), drain 2.3 %.

**Findings:**

- **TCP RX ~90 (median 90.4), ≈−3.4 % below the historical ~93.5 line-rate.**
  This is the v2.23 safe-default RX checksum policy (`rtl8196e_rx_set_csum`):
  TCP is verified by the stack instead of trusting the switch's uncharacterised
  checksum bits. An isolated same-build A/B (`rtl8196e_csum_blanket` toggle,
  2026-07-17) put the cost at **~4.4 % at 8-stream saturation** (blanket 93.9 vs
  gated 89.8) and **~2 % single-stream** — this run matches it (P8 88.7,
  1-stream 90.0). A deliberate integrity/throughput trade, not a regression to
  chase; rationale in `DESIGN.md` / `SPECIFICATIONS.md`.
- **TCP TX median 71.5 over 10 reps sits at the top of the ~69–73 band** — the
  audit hardening costs nothing on TX, and the coalescing path is healthy
  (24.6 % threshold kicks, 2.3 % batch-end drain).
- **Sustained 300 s clean:** 90.1–91.5 Mbit/s, RetransSegs 0.0000 % over ~2.4 M
  segments, all ring-anomaly and switch-core recovery counters at zero. The
  small `rx_drop` (304–439) is core/GRO delivery under the UDP flood (0.008 % of
  RX), not the Ethernet ring.
- **UDP unchanged:** TX 32.9 (CPU-bound sender), RX loss is receiver
  socket-buffer saturation at the offered rate — the documented flood behaviour,
  no hardware error.

## Kernel 7.1.3 confirmation run — driver v2.23, TCP RX/TX (2026-07-17)

Same driver **v2.23** on the **7.1 supported line** at **7.1.3**
(`7.1.3-rtl8196e-v4.0.0-rc5 #3`), flashed to `.88`, OTBR stopped
(`S70otbr stop` + `killall keepalive otbr-agent otbr-monitor`, `ps` clean),
wired host link, `iperf3` 3.18/3.16. Scope is the **two headline TCP tests**
only (RX + TX), run with the *same* per-rep protocol as the 6.18.38 median
run above — a fresh gateway server + client per rep, 30 s, 8 s inter-session
gap, **median** reported — so the two kernel lines are directly comparable.

| Workload | Reps | Median (Mbit/s) | Spread | 6.18.38 v2.23 |
|---|:--:|--:|---|--:|
| TCP RX (host→gw) | 3 | **88.6** | 88.2–88.9, σ 0.29 | 90.4 |
| TCP TX (gw→host) | 10 | **69.6** | 68.1–70.4, σ 0.68 | 71.5 |

Fresh boot, so cumulative counters ≈ this bench: eth0 **rx errors 0 / tx
errors 0**, **TCP RetransSegs 0** over 1.83 M segments, retrans 0 on every
rep, and **all ring-anomaly and switch-core recovery counters at 0**
(`rx_wild_*`, `rx_bad_len`, `rx_*_runout_*`, `swcore_deep_reset`,
`swcore_reprogram_fail` = 0). `rx_drop 330` (~0.02 % of 1.6 M pkts) is
core/GRO delivery, not a ring error — the same class as the 6.18.38 run's
304–439.

**Finding — 7.1.3 is on par with 6.18.38, ~2 % lower on both medians.** RX
88.6 vs 90.4 (−2.0 %) and TX 69.6 vs 71.5 (−2.7 %). The TX delta is inside
the documented run-to-run TX spread (69.3–72.8 across sessions with no driver
change); 7.1.3 lands at the low edge of that band rather than the high edge
the 6.18.38 run happened to hit — not a regression. RX carries the same v2.23
safe-default checksum policy (TCP verified by the stack), so both sit below
the pre-v2.23 ~93.5 line-rate by design. No retrans, no ring errors, no
recovery events on either line: the 7.1 kernel is a clean throughput-equal
alternate to 6.18.

## Standardized release bench — v4.0.0 / driver v2.24 / kernels 6.18.41 + 7.1.7 (2026-08-08)

Both lines moved up for the 4.0.0 release — 6.18.38 → **6.18.41**, 7.1.3 →
**7.1.7** — and `CONFIG_WIREGUARD` was dropped from both configs. Driver
**v2.24** unchanged. Host `Gigabyte` direct via `enp2s0`, `iperf3` 3.18 both
ends, OTBR **and** netwatch stopped and verified at zero processes before each
run (`ps` filtered), `scripts/bench_release_iperf3.sh` with its default reps.

**6.18.41 — two independent full runs:**

| Workload | Reps | Run 1 | Run 2 |
|---|:--:|--:|--:|
| TCP RX (host→gw) | 3 | **89.5** (89.1–90.2) | **89.3** (89.2–90.0) |
| TCP TX (gw→host) | 10 | **68.5** (67.3–70.5, σ 0.93) | **68.4** (67.4–69.4, σ 0.71) |
| TCP stress (host→gw, 300 s) | 1 | 89.5 | 90.4 |
| UDP TX (gw→host, `-b 0`) | 3 | 32.2, 0 % loss | 32.3, 0 % loss |
| UDP RX (host→gw, `-b 100M`) | 3 | 33.0, 66 % loss | 33.5, 65 % loss |

Both runs: **rx_errs 0, tx_errs 0, tx_drop 0**, `rx_drop` 437 / 438, and
**RetransSegs 0 (0.0000 %)** over 1.88 M / 1.88 M segments. The two medians
reproduce to **0.1 on TX and 0.2 on RX** — the kernel is stable, not merely
acceptable once.

**7.1.7 — single full run** (n = 1; the 6.18 line got the repeat, this one did
not):

| Workload | Reps | Median (Mbit/s) | Spread / loss |
|---|:--:|--:|---|
| TCP RX (host→gw) | 3 | **88.8** | 87.9–88.9 |
| TCP TX (gw→host) | 10 | **70.0** | 69.0–71.2, σ 0.69 |
| TCP stress (host→gw, 300 s) | 1 | 89.0 | retrans 0.0000 % |
| UDP TX (gw→host, `-b 0`) | 3 | 31.4 | 0 % loss |
| UDP RX (host→gw, `-b 100M`) | 3 | 35.5 | 63 % loss |

Same clean counters: rx/tx errors 0, tx_drop 0, RetransSegs 0 over 1.91 M
segments.

**Findings:**

- **6.18.41 is level with 6.18.38.** Measured in the same campaign and the same
  protocol, 6.18.38 gave TX 69.1 / RX 91.4. The TX delta (−0.6) is inside the
  ±0.9 repeatability measured below; the RX delta (−1.9) is not resolvable
  either, for the reason in the next point.
- **The production line deliberately stops at .41.** Benching every point
  release of the interval, paired and back to back, puts the last good release
  at .41 and the first bad one at .42: 68.2 / 68.3 / 68.8 / **68.8** on
  .38/.39/.40/.41, then **66.0** on .42 and 66.8 on .43. The ~2.2 Mbit/s TX loss
  at .42 is not attributable to any single commit — reverting all of `net/`
  restores it, no subgroup does — and whether it is extra work or a different
  link layout was not settled.
- **7.1.7 gains on 7.1.3** (70.0 against 68.2 in the same paired series) and now
  edges past the 6.18 line on TX while sitting ~0.6 below it on RX. 7.1 stays
  opt-in regardless: 6.18 is longterm, 7.1 is an ordinary stable that goes EOL
  when 7.2 ships.

**Two caveats that bound every number above:**

1. **The RX band is where v2.23 put it, and this document already said so.**
   The ~93.5–94 figures at the top predate the v2.23 gated RX checksum policy
   (`rtl8196e_rx_set_csum`), priced in the 2026-07-17 entry above at ~2 %
   single-stream and ~4.4 % at 8-stream — a deliberate integrity/throughput
   trade. Post-v2.23 the line sits at 89.5–91.7, and nothing in this campaign
   exceeded **91.7** on any kernel or config. `THR_RX_FLOOR` in
   `bench_release_iperf3.sh` was lowered 93 → 88 to match a band the driver
   chose, not to paper over a drift.
2. **Noise floors were measured rather than assumed** (2026-08-08). The
   byte-identical figure was first estimated at **±0.9** from a null control at
   **n=2** (reverting 112 files the config does not compile). Re-measured the
   same evening at **n=8** — one saved image reflashed eight times, md5 checked
   at every point, same protocol — it is **wider**:

   | | mean | **sd** | observed n=8 range |
   |---|--:|--:|--:|
   | TCP TX | 69.71 | **0.62–0.70** | 2.0 |
   | TCP RX | 90.76 | **0.47–0.50** | 1.2–1.4 |

   **The sd is the characterisation; the range is not.** A range grows
   mechanically with n — 30 points would show a wider one without the bench
   being noisier — so 2.0 and 1.2–1.4 mean "observed range at n=8 under this
   protocol", nothing more.

   **There is no threshold below which an effect is undetectable.** A paired
   mean resolves far below the spread of individual observations: with these
   sds, the difference of two independent points has sd ≈ 0.68, so eight pairs
   give a standard error of 0.24 and a +0.70 effect is ~2.9 SE. The correct
   rule is that **an isolated delta below the observed range cannot be
   interpreted on its own — it needs paired repetition and an uncertainty
   interval.**

   The other measured spreads stand: **1.9** across a padding sweep of 0 to
   78 656 bytes, up to **3.8 on RX** from code placement *inside* `net/`, and
   **2.0** between sessions hours apart. Several conclusions drawn during this campaign died against
   them.

**Why the 4.0.0-rc numbers above are not directly comparable.** From `0f71082`
(2026-08-03) until this release, both kernel configs carried
`CONFIG_WIREGUARD=y`. That option costs **3.7 Mbit/s of TX** on this SoC while
never executing a single instruction: it is declared at `drivers/net/Makefile`
line 13, ahead of `ethernet/` and so ahead of the whole network stack, and its
~71 KiB displace every hot symbol downstream — `rtl8196e_poll` by 81 920 bytes,
`softnet_data` by 90 368. Padding the same link slot with 71 392 bytes of inert
data reproduces the loss exactly, and the symbols WireGuard *selects* cost
nothing on their own, which is what identifies placement rather than code as
the cause. Any bench taken on a build between those dates carries that penalty.

## `csum_partial` into on-chip SRAM — paired, n=5 (2026-08-08)

The gated-checksum policy of v2.23 (above) made `csum_partial` a per-RX-packet
function, still fetched from SDRAM. The RTL8196E's I-MEM window is **always**
16 KiB whatever `.iram` holds, and only 8 700 B were in use — the rest was
inter-section padding. Moving `csum_partial` (1 432 B) there takes `.iram` to
10 144 B and drops `.text` by 1 440.

Five interleaved `base`/`csum` pairs across three sessions, radio quiesced and
verified at zero processes before each point:

| pair | RX base | RX `.iram` | Δ RX | TX base | TX `.iram` | Δ TX | suite |
|---|--:|--:|--:|--:|--:|--:|---|
| 1 | 89.1 | 91.1 | +2.0 | 69.1 | 69.4 | +0.3 | short |
| 2 | 89.9 | 90.8 | +0.9 | 68.5 | 69.4 | +0.9 | short |
| 3 | 89.5 | 90.7 | +1.2 | 68.2 | 69.7 | +1.5 | short |
| 4 | 88.9 | 90.2 | +1.3 | 68.3 | 69.8 | +1.5 | short |
| 5 | 89.7 | 90.4 | +0.7 | 68.6 | 69.3 | +0.7 | **full** |
| | | | **+1.22** | | | **+0.98** | |

Ten directional deltas across five pairs, all positive; RX distributions
disjoint — the best baseline (89.9) stays below the weakest treated run (90.2).
A sign test on five same-signed pairs gives p ≈ 0.031 one-sided per direction.
No single pair clears the observed n=8 range — which is why the paired series,
not any single pair, is the evidence.

**Read the TX column with the compensated control below.** All five pairs ran
`base` first, and the balanced ABBA run shows a positional effect on TX of about
+0.88 — the size of the +0.98 reported here. The TX gain is **not supported by a
balanced ordering** and should be treated as unconfirmed. The RX column shows no
positional effect in the balanced run and survives, reduced.

The post-v2.23 RX band moves from **89.5–91.7** to roughly **90.2–91.5** in
practice, still inside the `THR_RX_FLOOR = 88` gate.

Pairs 1–4 ran a shortened suite (`REPS_TX=5`, `DUR_STRESS=10`). **Pair 5 is the
full release suite**, run on 2026-08-08 to confirm the shipped kernel:

| Workload | Reps | base `#1` | `csum` `#2` |
|---|:--:|--:|--:|
| TCP RX (host→gw) | 3 | 89.7 (88.2–89.7) | **90.4** (90.1–91.8) |
| TCP TX (gw→host) | 10 | 68.6 (67.0–69.5, σ 0.80) | **69.3** (68.3–71.2, σ 0.88) |
| TCP stress (host→gw, 300 s) | 1 | 88.5 | **90.5** |
| UDP TX (`-b 0`) | 3 | 32.1, 0 % loss | 32.5, 0 % loss |
| UDP RX (`-b 100M`) | 3 | 31.8, 67 % loss | 31.4, 67 % loss |

Both: `rx_errs` 0, `tx_errs` 0, `tx_drop` 0, `rx_drop` +438 / +437, and
**RetransSegs 0 (0.0000 %)** over 1.87 M / 1.91 M segments. The suite's own gate
separates them — the baseline trips `TX < 69` at 68.6, the treated kernel clears
it. `csum_partial` was confirmed at `0x8032e200` in `/proc/kallsyms` on the
running box, inside the `.iram` window, before the second run started.

**Status after the compensated control below: RX gain probable, TX not
confirmed, a confirmatory series still required.** All five pairs above ran
`base` before `csum`, and a later balanced run shows that ordering alone moves
TX by about the size of the reported TX gain. Read the five-pair TX figure as
unsupported until the confirmatory series lands. The remaining 5.9 KiB of window
is not free throughput either. An earlier attempt to
add 4 280 B more of the per-packet path (`__dev_queue_xmit`,
`dev_hard_start_xmit`, `__netif_receive_skb`, `netif_receive_skb_list_internal`,
`dev_gro_receive`, `gro_complete`) measured **−0.30, i.e. nothing**, against a
per-variant spread of 1.4.

### Compensated control — `.space 0x598`, ABBA-ordered, n=4 (2026-08-08)

The five pairs above confound the I-MEM placement with the `.text` reshuffle it
causes, and they all ran in one order. This control removes both.

Three variants of the same tree, differing only in `arch/mips/lib/csum_partial.S`:

| | `csum_partial` | `.text` | `.iram` |
|---|---|--:|--:|
| **A** | `.text`, vanilla | 3 312 688 | 8 700 |
| **B** | `.iram` (shipped) | 3 311 248 | 10 144 |
| **C** | `.iram` + `.space 0x598` at the original location | **3 312 688** | 10 144 |

**C verified against the A binary before benching**: of 15 045 common `.text`
symbols exactly **one moved** — `csum_partial` itself — and **no** `.data`,
`.bss` or `.rodata` symbol moved. The active-data addresses and all other
function addresses are preserved; remaining differences are confined to the
relocated function, its compensated text slot and address-bearing metadata not
exercised by the benchmark.

Four pairs, **ABBA order** (`A C | C A | A C | C A`), shortened suite matching
pairs 1–4 above, radio quiesced at each point, `csum_partial`'s address re-read
from `/proc/kallsyms` on the running box after every boot:

| pair | order | Δ RX (C−A) | Δ TX (C−A) |
|---|---|--:|--:|
| 1 | A→C | +0.6 | +1.5 |
| 2 | C→A | +0.5 | −1.0 |
| 3 | A→C | +0.4 | +0.5 |
| 4 | C→A | +1.3 | −0.5 |
| | **mean** | **+0.70** | +0.12 |
| | positive | **4/4** | 2/4 |

**RX**: +0.70, 4/4 positive, no order effect visible (odd positions 89.45, even
89.25). The result is consistent with an instruction-side RX gain and removes
the known text/data-address reshuffle confounds, but **four pairs do not
establish it at the declared significance threshold** — a sign test on 4/4 gives
p = 0.0625 one-sided, and +0.70 is the same order as the observed variability.
"No order effect" means none visible in eight points, not none present.

**TX**: no variant effect (A 68.40, C 68.53). A post-hoc odd/even positional
pattern was noted here (odd 68.1/68.1/67.9/68.0, even 69.6/69.1/68.4/68.5,
complete separation, permutation p ≈ 0.014) — and **the controlled reproduction
that followed refuted it**. Eight reflashes of one identical image gave an
odd/even gap of only +0.33 with no separation (p = 0.271), and a byte-identical
TX range of **2.0**. The compctl separation was a coincidence in a population
whose natural range is twice what we had been quoting.

Repeatability across **same-source rebuilds** (consecutive points where the
source content was unchanged but the tree was rebuilt and relinked, so the
binaries are not byte-identical): Δ TX 1.5 / 1.2 / 0.4, Δ RX 0.1 / 1.2 / 0.7.
The proper byte-identical measurement was made afterwards — one saved image
reflashed eight times — and gives **TX sd 0.62–0.70, RX sd 0.47–0.50** (observed
n=8 ranges 2.0 and 1.2–1.4). Read every effect in this file against the sds and
against a paired standard error, not against a range treated as a threshold.

**Not yet decomposed.** `C − A` is the compensated I-MEM effect, `B − C` the
reshuffle, `B − A` the shipped total. Comparing the +0.70 here against the +1.22
of the five-pair series is a decomposition *hypothesis*, not an estimate: the two
came from different sessions with different n. A proper decomposition needs A, B
and C in one balanced campaign (ABC / BCA / CAB and their reverses).

**Uncontrolled variable found while investigating**: the bench never flushes the
host's cached TCP metrics. `ip tcp_metrics show 192.168.1.88` returned an entry
aged 5 h with `cwnd 10`. Restarting `iperf3` per rep does not reset what the host
remembers per destination. Any future series should `ip tcp_metrics flush all`
before each point.

## I-cache geometry, measured (2026-08-08)

`CONFIG_RTL8196E_ICACHE_PROBE` (default n, `arch/mips/realtek/icache_probe.c`)
times generated jump chains from KSEG0. Result, identical across four base
offsets:

**2-way set-associative, 8 KB per way.** The 16-byte line size is documented and
consistent with the result but was **not** measured independently — the probe's
blocks are 16 B by construction.

The model predicts not just the knee (N=3 at 8/16/32 KB strides, N=5 at 4 KB,
N=9 at 2 KB) but the partial-thrashing values: 3-of-5 blocks conflicting reads
60 % of the full penalty, measured 120–124k ps against 200k. Effective penalty
**~200 ns per conflicting block in that synthetic chain** (~80 cycles at
400 MHz) — not necessarily the latency of an isolated miss.

**Two ways do not help here, because the way is 8 KB**: 512 sets, not 1024, and
doubling the ways does not compensate for halving the sets. Oversubscribed sets
go from 583/1024 (57 %, the old direct-mapped estimate) to **394/512 (77 %)**,
with up to 7 hot functions sharing a 2-way set.

**What this does not settle.** The residual hot set is 1925 lines, 188 % of the
cache; grouping and spreading it uniformly would take the static excess from 953
to 901 lines. An earlier reading called that 52-line difference a bound on the
achievable gain and concluded the placement avenue was closed. **That was
wrong**: it bounds the reduction of an *unweighted static line count*, not cache
misses and not throughput. Lines are not equivalent — some never execute, some
run once per packet, some repeatedly, and `tcp_ack`/`tcp_write_xmit` branches
are mutually exclusive by connection state. One can hold the static count at 953
while moving collisions off the hottest lines, and the dynamic miss count can
fall sharply.

The gate outcome is therefore **LIMITED GO**, not STOP: blind grouping of all 28
whole function bodies is unjustified, targeted placement after a *dynamic*
measurement is not. The missing input is execution frequency per function, and
ideally per basic block inside the large TCP functions.

## Two assembly copy cores into on-chip SRAM (2026-08-09)

The phase-2 dynamic profile (PC sampling at 16-byte buckets, RX and TX
separately) ranked two shared assembly bodies far above everything else per byte
of function:

| body | size | % RX work | % TX work | % per KB |
|---|--:|--:|--:|--:|
| user-copy core (`__raw_copy_{to,from}_user`, `memcpy`) | 700 B | 41.5 | 20.4 | **90.6** |
| checksum-copy core (`__csum_partial_copy_*`) | 856 B | — | 15.1 | 18.1 |
| `dev_gro_receive` | 1 592 B | 3.2 | 1.0 | 2.7 |
| `tcp_ack` | 5 056 B | 0.4 | 1.7 | **0.4** |

`tcp_ack` headed every pair in the earlier *static* conflict model and returns
0.4 % per kilobyte; the copy core returns 220 times more. Both bodies move to
`.iram`, taking it from 10 144 to 11 712 B of the 16 KiB window.

Three patches per line: `arch/mips/lib/memcpy.S`,
`arch/mips/lib/csum_partial.S`, and `scripts/mod/modpost.c` to authorize `.iram`
as an `__ex_table` fixup target — required, because the copy-user routines carry
exception entries for faults on user pointers.

### Measured, pre-registered

Eight paired A/B runs of the **production form** (no compensating padding, no
linker anchor), balanced order, one saved image per variant with md5 verified at
every flash, `REPS_TX=10`, `REPS_RX=3`:

| | mean | 95 % CI | positive |
|---|--:|---|---|
| **TCP TX** (primary) | **+1.387** (+2.0 %) | [+0.63, +2.15] | 7/8 |
| **TCP RX** (guard-rail) | **+1.875** (+2.1 %) | [+1.54, +2.21] | 8/8 |

Gain positive in both orderings (+1.67 A-first, +1.10 P-first); nothing
indicates the ordering explains it.

**The pre-registered utility gate was not formally cleared.** The rule was
"ship if the interval crosses the threshold"; the TX lower bound (+0.63) sits
0.07 Mbit/s under the 0.70 declared bar. The point estimate is twice the bar and
RX is unambiguous, and the change ships on the maintainer's decision with that
noted. Settling the TX gate would need a fresh pre-registered series of 12–16
pairs, not an extension of this one.

**Not established**: the mechanism. The gain may come from on-chip SRAM latency,
from an avoided I-cache conflict, or both. The measured geometry (2-way, 8 KiB
way, 16-byte lines) makes the second plausible without demonstrating it.

Earlier compensated variants, same baseline, for reference: copy core alone
+0.638 TX [+0.14, +1.14]; both cores +1.188 TX [+0.74, +1.63]. The RX difference
between those and the production form is **compatible** with the `.text`
reshuffle the production form carries, but the two are separate sessions and the
gap cannot be decomposed.

### Verified before shipping

- **Exception table**: 477 entries — 105 with instruction *and* fixup in
  `.iram`, 372 with both in `.text`, **zero straddling**.
- **Displacement**: 236 of 14 310 `.text` symbols move; **nothing** in `.data`,
  `.rodata` or `.bss`. `softnet_data`, `net_hotdata`, `init_task`, `tcp_ack` and
  `rtl8196e_poll` keep identical addresses.
- **User-fault recovery, on the board**: read to a bad address, write from a bad
  address through a real file and through a pipe, and `sendto` from a bad
  address to exercise `csum_partial_copy_from_user` — all four return `EFAULT`
  cleanly, a normal read still works, no oops.

## Standardized release bench — copy cores in I-MEM, both lines (2026-08-09)

First full-suite run of the shipped change (commit `b098be4`, images
`6735547b1f4b` for 6.18 and `65ed024d7b76` for 7.1). Board `lidl`, host direct
Cat-6 on `enp2s0`, radio quiesced and verified at zero processes, each line from
a fresh flash and boot.

| Workload | Reps | **6.18.41** | **7.1.7** |
|---|:--:|--:|--:|
| TCP RX (host→gw) | 3 | **92.8** (91.9–93.2) | **89.4** (89.4–90.6) |
| TCP TX (gw→host) | 10 | **70.7** (69.2–71.9, σ 0.80) | **72.2** (70.7–73.0, σ 0.60) |
| TCP stress (host→gw, 300 s) | 1 | 91.7 | 89.5 |
| UDP TX (`-b 0`) | 3 | 33.2, 0 % loss | 32.2, 0 % loss |
| UDP RX (`-b 100M`) | 3 | 32.4, 66 % loss | 38.3, 60 % loss |

Both lines: `rx_errs` 0, `tx_errs` 0, `tx_drop` 0, `rx_drop` +435 / +439, and
**RetransSegs 0 (0.0000 %)** over 1.94 M / 1.97 M segments. Both PASS.

The split is clean and opposite: **6.18 leads by 3.4 on RX, 7.1 by 1.5 on TX.**

**These are two single runs, not a paired comparison**, taken ~45 minutes apart.
Nothing about the 6.18-versus-7.1 difference should be read as settled: the
campaign of 2026-08-08/09 showed that differences of this size need interleaved
pairs. The paired figures for the I-MEM change itself are the eight-pair series
recorded above (+1.39 TX, +1.88 RX), not these numbers.

Against the v4.0.0 reference in this file — 6.18 at RX 89.5/89.3 and TX
68.5/68.4 — the 6.18 line reads +3.4 RX and +2.2 TX. Again single runs against a
historical session, and larger than the paired measurement, so the paired
figures remain the ones to quote.

**The 6.18 RX at 92.8 is worth flagging**: this file previously recorded the
post-v2.23 band as 89.5–91.7, with nothing exceeding 91.7 on any kernel or
config tried across 2026-08-07/08. The ceiling has moved.

### One discarded run, and why

The first 7.1 attempt reported TX 72.7 with **spread 17.7, σ 5.06**, one rep at
55.7 against neighbours at 72.5. NIC counters were clean, the link was 1000
Mb/s full duplex with zero errors, and retransmissions were zero — so it looked
like an unexplained board stall and was first reported as one.

It was self-inflicted: four SSH logins landed inside that TX block while a
helper script was being tested. A dropbear login does ed25519 crypto on a
400 MHz core with no accelerator, and during a TX test the gateway is the
sender, so that CPU is exactly what is being measured. The relaunch above, from
a fresh flash with no connection during the measurement, gives σ 0.60 — the
outlier is gone and the median barely moves (72.7 → 72.2), which is what a
median over ten reps should do.

The rule is now in this tree's `CLAUDE.md` and `AGENTS.md`: never touch the
gateway while a bench is running, and always bench from a fresh flash and boot.

## TX path per-packet decomposition (driver v2.4 + Track A, probe-on)

**Superseded by the 2026-07-02 re-measurement below** ("TX/RX per-packet
CPU decomposition — driver v2.20") — this table only ever decomposed
`start_xmit()` itself (`rtl8196e_poll()` was never instrumented), and the
"~6 % of total" claim in `## Asymptote and bottleneck` below was an
*inference* from an assumed CPU budget, not a direct measurement. Kept
here as historical record.

Captured during the v3.4.1 perf session with the optional `ktime_get()`
probes from the `feat/tx-throughput` branch (`xmit_probe`, `kick_probe`,
`cache_probe` — module parameters + sysfs, single-shot brackets).  Probe
code is **not** on main; cherry-pick from the archive branch when
re-running.  60-second TCP TX, ~370 k packets per probe:

| Phase                                         |   ns/pkt | % of start_xmit |
|-----------------------------------------------|---------:|----------------:|
| `dma_cache_wback_inv(skb->data, skb->len)`    |    1 675 |          15.4 % |
| `rtl8196e_ring_kick_tx` (CPUICR pulse)        |    1 444 |          13.3 % |
| Other (submit + reclaim + stats + branches)   |    7 733 |          71.3 % |
| **Total `start_xmit`**                        | **10 852** |        100 %  |

The "other" 71 % is dominated by `rtl8196e_ring_tx_submit` (descriptor
fill + 2 small descriptor flushes) and the unconditional `tx_reclaim`
call.  At ~5 800 packets/s for 70 Mbit/s, `start_xmit` accounts for
~6 % of total CPU time per packet — the rest of the ~132 µs/packet
budget sits in the TCP/IP send-side stack and the soft-IRQ NAPI poll
that processes incoming TCP ACKs.

## Why is TCP TX roughly 75 % of TCP RX?

100BASE-TX is full-duplex with two physically independent channels at
100 Mbit/s each, so RX line-rate at 93.5 Mbit/s confirms the DMA
engine, switch fabric, and ring management work at near line-rate.
The 25 % TX deficit is **not** a hardware bottleneck.  It is a
structural consequence of the writeback cache and the software-managed
DMA coherency model.

### TX: each byte traverses the DRAM bus twice

The Lexra RLX4181 has a write-back L1 cache and no DMA coherency
hardware (no snooping, no write-through).  TX requires `dma_cache_wback_inv()`
on the packet data so the switch ASIC sees current values:

```c
dma_cache_wback_inv(skb->data, len);   /* writeback dirty lines, then invalidate */
dma_cache_wback_inv(ph, sizeof(*ph));
dma_cache_wback_inv(mb, sizeof(*mb));
```

1. The application (iperf) writes the payload → dirty in L1.
2. `tcp_sendmsg` copies user → kernel skb → more dirty lines.
3. `dma_cache_wback_inv()` forces every dirty 16-byte cache line to be
   written back to DRAM before the DMA engine can read it.

Each payload byte therefore traverses the DRAM bus **twice** from the
CPU's perspective: once when written to the socket buffer, once when
flushed for DMA coherency.  The CPU stalls during each writeback —
this is synchronous on this architecture.

### RX: each byte traverses the DRAM bus once

The DMA engine writes received payloads directly into DRAM, bypassing
the CPU cache entirely.  The driver's RX path only needs `dma_cache_inv()`
to mark the corresponding cache lines invalid — no DRAM write happens.
The application then incurs ordinary cache misses when reading.

### Rough cycle cost per 1 500-byte packet

| Operation                    | TX                                     | RX                            |
|------------------------------|----------------------------------------|-------------------------------|
| Data cache op (~94 lines)    | ~94 × (writeback + inv) ≈ 300 cycles   | ~94 × inv ≈ 50 cycles         |
| Descriptor cache ops         | ~4 × (writeback + inv) ≈ 24 cycles     | ~4 × inv ≈ 8 cycles           |
| **Total cache overhead**     | **~324 cycles (~0.85 µs)**             | **~58 cycles (~0.15 µs)**     |

The 6× difference in cache overhead per packet is the dominant
contributor to the TX/RX asymmetry, compounded by the secondary
factors below.

### Secondary factors

**Software TCP checksum (TX only).** The RTL8196E switch verifies
IP/TCP checksums on received frames in hardware (driver sets
`CHECKSUM_UNNECESSARY` for RX).  For TX, no checksum offload is
declared, so the kernel computes it in software over every segment
(~1460 bytes).  Real but secondary.

**TCP send-side stack is heavier than receive-side.** The sender runs
congestion control (cwnd, RTT estimation, pacing) and processes
incoming ACKs.  The receiver mostly reassembles in-order data and
delivers to the socket buffer.  Both have overhead, but the sender
path is consistently more expensive per byte on this CPU.

## Asymptote and bottleneck

Measured TCP TX ceiling on this SoC ≈ **71 Mbit/s** under iperf2
single-stream conditions, CPU pegged at 99 % (sys + sirq).  The TX
ceiling is set by:

- the TCP/IP send-side stack (~80–90 µs of CPU per packet),
- the DDR memory bus during data writebacks (1500-byte flush ≈
  1.4 µs ≈ 84 % of cache-flush time on this slow bus),
- the absence of useful hardware instructions (RLX4181 is strict
  MIPS-1 — no `pref` for prefetch, no FPU, no `lwl`/`lwr`/`swl`/`swr`
  for unaligned access).

The driver hot path (`start_xmit`) consumes ~6 % of CPU time per
packet — most of the remaining ~94 % is in the network stack and
NAPI processing of the TCP ACK return traffic.  Tuning the driver
beyond Track A's +1.2 % coalescing has no measurable effect on
throughput, as documented in the orthogonal-levers session.

**Superseded, 2026-07-02:** the "~6 %" figure above never measured
`rtl8196e_poll()` — see "TX/RX per-packet CPU decomposition — driver
v2.20" below, which found the driver's own code (`start_xmit` +
`poll()` combined) accounts for **~32 %** of total per-packet CPU, not
~6 %. The conclusion that further driver tuning has little effect on
*throughput* still holds (unchanged from the orthogonal-levers data),
but the reason is different from what this paragraph assumed.

## Levers explored — orthogonal-levers session 2026-05-02

A dedicated measurement session evaluated four orthogonal levers
proposed by `BRIEF-tx-throughput-orthogonal-levers.md`.  Conditions:
kernel 6.18.24, driver v2.4, 5 × 60 s per workload, medians below,
intra-phase variance ≈ 1 % (significance threshold 2σ ≈ 2 %).

| Workload (Mbit/s) | R₀ baseline |     A |    B+ |     C |     D |
|-------------------|------------:|------:|------:|------:|------:|
| TCP RX            |        93.5 |  93.4 |  93.3 |  93.3 |  93.3 |
| **TCP TX**        |    **69.3** |**70.1**| 69.3 |  69.5 |  69.3 |
| UDP TX 100M       |        37.9 |  37.9 |  37.6 |  37.5 |  37.0 |
| UDP storm 64 B    |        1.88 |  1.87 |  1.87 |  1.90 |  1.84 |

| Track                                          | Δ TCP TX | Verdict   |
|------------------------------------------------|---------:|-----------|
| A — `kick_tx` coalescing (N=4 + NAPI drain)    | +1.2 %   | Kept (v3.4.1) |
| B+ — TX flush writeback-only (skip invalidate) | −1.1 %   | Reverted  |
| C — NAPI weight 64 → 128                       | −0.9 %   | Reverted  |
| D — Full TX scatter-gather (`NETIF_F_SG`)      | −1.1 %   | Reverted  |

No lever moved RX or either UDP workload outside noise, so the three
rejections are rejections on every workload measured, not just on the
TCP TX column the session was aiming at.

**A** pulses `TXFD` on `CPUICR` at most once per 4 submits (except a
cold-start `was_empty`), drained at the end of every NAPI poll —
roughly 3 µs of MMIO bus time saved per 4-packet batch.  Its +1.2 %
sits at the variance edge but was consistent across all 5 reps
(71.2 / 69.9 / 70.2 / 69.9 / 70.1, median 70.1 against R₀ 69.3).

**B+** was expected to win by keeping the TX buffer warm; it lost.
With an 8 KB D-cache a 1500-byte frame is ~19 % of the cache, and
holding it evicts lines the stack still needs — the invalidate frees
the cache better than the warm-keeping pays.  `dma_cache_wback_inv`
stays the right call on this hardware.

**C** lost on a single core: a larger NAPI weight starves process
context (the `start_xmit` syscall) in favour of poll.  The default 64
is well matched to this CPU.

**D** is notable: the HW probe (`rtl8196e_ring_tx_sg_test`) confirmed
the switch ASIC honours mBuf `m_next` chains on TX, contradicting the
mbuf.h comment "MBUF_EOR is set only by ASIC" (true on RX only) — a
96-byte two-mBuf chain reached the wire intact, with the payload
pattern crossing the mBuf boundary.  The full SG path was implemented
and runs correctly (99.96 % non-linear SKBs once `NETIF_F_SG` is
advertised) but splitting one big 1500 B cache flush into N small
flushes (head + frags) costs more than skipping `skb_linearize` saves
on this CPU.

The brief had projected 5–15 % per track.  Measured reality was
±1.5 % noise on all four, with only A net-positive at the threshold —
which is what redirected the investigation away from the driver hot
path and towards the stack and the DDR bus.

Implementation, instrumentation, and full bench data for all four
tracks are preserved on the `feat/tx-throughput` archive branch.

## In-driver instrumentation (archive branch)

Three optional probes for future perf work live on the
`feat/tx-throughput` archive branch.  They are **not** included on
main: the production driver carries no `ktime_get()` instrumentation
in the hot path.  When perf work is needed, cherry-pick the two
relevant commits and rebuild:

```bash
git checkout main
git cherry-pick 382c837 33fdac2     # probe import + kick/cache extension
./build_kernel.sh && ./flash_remote.sh -y kernel <gateway-ip>
```

Once the probe build is flashed, each probe is gated independently to
limit `ktime_get()` overhead per packet (~0.2–0.4 µs, one read + one
helper call out of IRAM):

```bash
# Toggle a probe (writes to module parameter):
echo Y > /sys/module/rtl8196e_eth/parameters/rtl8196e_xmit_probe
echo Y > /sys/module/rtl8196e_eth/parameters/rtl8196e_kick_probe
echo Y > /sys/module/rtl8196e_eth/parameters/rtl8196e_cache_probe

# Read accumulated stats (count / sum_ns / max_ns + log2 histogram):
cat /sys/class/net/eth0/xmit_probe_stats
cat /sys/class/net/eth0/kick_probe_stats
cat /sys/class/net/eth0/cache_probe_stats

# Reset between runs:
echo 1 > /sys/class/net/eth0/xmit_probe_reset
```

The archive branch also carries the bench harness
(`scripts/bench_tx.sh`) that drives the probes during a 5 × 60 s sweep
across TCP RX/TX, UDP TX 100M, and UDP storm 64B workloads.

A second, separate archive branch, `perf/tx-rx-decomposition` (off
`optim_tx`, not `main`), carries a fourth probe (`poll_probe`,
bracketing all of `rtl8196e_poll()`) ported alongside the three above
onto the current driver — see the next section for what it measured.

## TX/RX per-packet CPU decomposition — driver v2.20 (2026-07-02, `perf/tx-rx-decomposition`)

The decomposition above only ever measured `start_xmit()`'s own
internals; the claim that "the rest is TCP/IP stack + NAPI ACK
processing" was an inference, not a measurement, and `rtl8196e_poll()`
(the NAPI RX/reclaim path — plausibly the *larger* of the two driver
entry points, since it's where GRO/stack delivery and
`napi_complete_done()`'s "~180 µs/cycle" cost documented above actually
execute) had never been instrumented. This session ported
`xmit_probe`/`cache_probe`/`kick_probe` onto the current `start_xmit()`
(main.c:564-666 — now carrying BQL, a retry path, and the
`tx_xoff_seen_*` counters, none of which existed at v2.4) and added a
new `poll_probe` bracketing all of `rtl8196e_poll()` (main.c:772-906).
Branch `perf/tx-rx-decomposition` (off `optim_tx` tip `15f1b51`,
commit `becf657`), archived on `private`, never merged — reproduce with:

```bash
git fetch private perf/tx-rx-decomposition
git checkout private/perf/tx-rx-decomposition
./build_kernel.sh && ./flash_remote.sh -y kernel <gateway-ip>
```

**Rig:** kernel `6.18.35-rtl8196e-v4.0.0-rc4`, driver
`2.20-tx-rx-probe`, gateway 192.168.1.88, host 192.168.1.200 (direct
Cat-6 on `enp2s0`), OTBR fully stopped, `iperf3 -c <gw> -R -t 30`
(gateway → host TX direction) × 5 reps per set, `sleep 2` between reps.
CPU-busy fraction from `/proc/stat` deltas measured *this session*, not
assumed from any prior doc — **not** `top`/`vmstat` (this BusyBox build
has no `vmstat`). Wall-clock duration taken from each rep's own
`iperf3` sender-interval report (10 ms precision): BusyBox `date` on
this rootfs does not support `%N` (`date +%s%N` returns garbage, not
nanoseconds) — discovered live, so `/proc/stat`-based deltas are paired
with the `iperf3`-reported window instead of a gateway-side timestamp.

Running all four probes simultaneously measurably inflated the very
quantity being measured (a calibration rep with only `xmit_probe`
enabled read 11,901 ns/pkt vs ~15,500 ns/pkt with `cache_probe` +
`kick_probe` also active — those two probes' own `ktime_get()` calls
sit *inside* `xmit_probe`'s bracket by construction, and `ktime_get()`
itself is not cheap on this core, no CP0 `Count`, falls back to
`timer-rtl819x`). To avoid this, the final numbers below come from two
**separately** probed 5-rep sets rather than one 4-probe run: **Set
A** (`xmit_probe`+`cache_probe`+`kick_probe`, `poll_probe` off) and
**Set B** (`poll_probe` only). A same-window 4-probe run was also taken
as a cross-check and landed within ~1 point of the separated result
(31.4 % vs ~32 %) — the conclusion is not sensitive to this choice.

**Table A — headline split:**

| Component | ns/pkt | % of total | Basis |
|---|---:|---:|---|
| `start_xmit()` (TX submit path) | 15,528 | ~9 % | **DIRECT** (`xmit_probe`, Set A median) |
| `poll()` attributable to TX-direction ACK stream | 40,098 | ~23 % | **DIRECT** (`poll_probe`, Set B median, `poll_sum_ns / tx_packets`) |
| **Driver-own total** | **55,626** | **~32 %** | DIRECT (sum of above two) |
| Generic TCP/IP stack + softirq (residual) | 115,800–119,835 | ~68 % | **DERIVED** (`total_cpu − driver_own`; includes probe self-overhead, see caveats) |
| **Total CPU per TX packet** | 171,430–175,461 | 100 % | DIRECT (`busy_frac × wall_ns / tx_packets`; range = Set B vs Set A, not the same window) |

`driver_own_pct` sensitivity range: **31.7 %** (Set A's own total_cpu)
to **32.5 %** (Set B's own total_cpu), central estimate **~32 %** —
reported as a range rather than a single figure because `start_xmit`
and `poll()` were measured in different reps, not literally the same
window (the two sets' own throughput, 65.3 vs 66.8 Mbit/s median, is
itself inside the documented noise band).

**Table B — internal `start_xmit()` decomposition** (Set A, cache/kick
probes nested inside `xmit_probe` by design — same as the v2.4 table):

| Phase | ns/pkt | % of start_xmit | v2.4 comparison |
|---|---:|---:|---|
| `dma_cache_wback_inv(skb->data, skb->len)` | 1,597 | 10.3 % | was 15.4 % (1,675 ns) |
| `rtl8196e_ring_kick_tx` (CPUICR pulse) | 970 | 6.2 % | was 13.3 % (1,444 ns) |
| Other (submit + reclaim + BQL + retry path + xoff counters + stats) | 12,962 | 83.5 % | was 71.3 % (7,733 ns) |
| **Total `start_xmit`** | **15,528** | **100 %** | was 10,852 ns |

Cache flush and kick both shrank as a *share* of `start_xmit` (kick's
absolute cost also dropped, 970 vs 1,444 ns — consistent with Track A's
kick-coalescing now amortizing most pulses across several submits,
confirmed by `ethtool -S eth0` showing the majority of
`tx_kicks_total` landing in `tx_kicks_threshold`, not `tx_kicks_cold`,
during every rep). "Other" grew both as a share and in absolute terms
(+5,229 ns) — expected, since `start_xmit` now does real additional
work the v2.4 measurement predates: BQL accounting
(`netdev_sent_queue`/`netdev_completed_queue`), the retry-on-failure
path, and the `tx_xoff_seen_xmit` counter check.

**Round 2 (same day) split the "other" bucket** with two more probes
(`submit_probe`/`reclaim_probe`, branch commit `e974949`): submit =
2,684 ns (17.3 %), **TX-reclaim block = 7,867 ns (50.7 %) — the
dominant phase of `start_xmit`**, rest ~2,411 ns. New always-on context
counters showed **73.5 % of TX packets are reclaimed in `start_xmit`
context** (`napi_budget=0` → `dev_consume_skb_any()`, bypassing the
NAPI bulk skb freelist credited by `POST-MORTEM-driver-perf.md` for
part of the 5.10→6.18 gains), only 26.5 % via `poll()`'s recycled path.
Deferring xmit-context frees to the poll freelist is therefore the
largest untested driver-side TX lever (ceiling ~7.9 µs/pkt ≈ 4.5 % of
total budget; realistically less). Full round-2 tables, the reclaim
split, and the 40 µs clocksource-quantization note live in
`TX-RX-CPU-DECOMPOSITION.md`.

**Verdict:** the driver's own code (`start_xmit` + `poll()` combined)
accounts for **~32 % of total per-packet CPU**, roughly **5× the old
"~6 %" inference**. This is not because `start_xmit` itself got much
more expensive (10,852 → 15,528 ns is real growth from BQL/retry/xoff,
but the same order of magnitude) — it's because the old figure never
measured `poll()` at all and silently attributed 100 % of
"everything else" to the generic stack. `poll()`'s TX-attributable cost
(40,098 ns/pkt) is actually **larger** than `start_xmit`'s own
(15,528 ns/pkt) — plausibly dominated by the GRO/stack-walk work this
document's own probe() comments already flagged as "~180 µs/cycle" for
`napi_complete_done()` alone, plus RX-ring housekeeping, TX reclaim,
`kick_drain`, and the RUNOUT/stall-detector checks that all run inside
the same call frame. This does **not** overturn "tuning the driver
beyond Track A has no measurable effect on throughput" — the
orthogonal-levers session already empirically tested several
driver-side changes and found ≤1.2 % throughput deltas despite
operating on what is now known to be ~32 % (not ~6 %) of the budget,
consistent with per-packet cost being dominated by cache-flush/MMIO
latency that driver logic changes don't reduce. It does shift where a
*future* lever would most plausibly land: `poll()`'s NAPI-batching
behavior (`napi_defer_hard_irqs`, `gro_flush_timeout` — both already
tuned, see the probe() comment above) rather than `start_xmit`'s
already-lean ~15.5 µs/pkt.

**Caveats:**
- Probe self-overhead is folded into the residual, not hidden: the
  ~3.6 µs/pkt inflation from `cache_probe`/`kick_probe` nesting inside
  `xmit_probe` is real (calibrated above), but since both
  `driver_own_ns_per_pkt` and `total_cpu_ns_per_pkt` in Set A come from
  the *same* overhead-inclusive window, the ratio stays internally
  consistent — it is not a hidden bias in `driver_own_pct` itself,
  though it does mean Set A's absolute ns/pkt figures run a few percent
  hot relative to an unprobed production build.
- All ring-anomaly counters (`ethtool -S eth0`) stayed 0 across every
  rep (20 total across the 4-probe run and the two separated sets) —
  the correctness gate held throughout, no rep excluded.
- `tx_ring_full` was 0 in every rep, so the retry path (§ above,
  "no special-casing") never actually fired during this bench —
  its handling is by design, not empirically exercised here.
- Median of 5 reps per set, matching this driver's noise-floor-aware
  bench convention; both sets' throughput (65.3, 66.8 Mbit/s) sits
  inside the "settled-low" band seen elsewhere this session (66–67),
  not the historical 69.3–72.8 band — a session/build variance
  consideration, not evidence of a regression.

## Driver v2.20 defer-frees gate run (2026-07-02, `optim_tx` branch)

Acting on the decomposition above (reclaim block = 50.7 % of
`start_xmit`; 73.5 % of TX skbs freed via `dev_consume_skb_any()` in
xmit context): `rtl8196e_ring_tx_reclaim()` gained a `defer` list
parameter — the xmit-context reclaim now parks completed skbs on
`priv->tx_defer_list` (cap 64, fallback to direct free past it) and the
NAPI poll drains them through `napi_consume_skb(skb, budget)`.
Descriptor slots are still released by the cursor advance at reclaim
time, so ring availability and BQL completion timing are unchanged —
only the skb free moves.

**Known mechanism caveat, identified before benching:** TCP TX skbs
reaching the driver are fast clones (`tcp_transmit_skb()` transmits a
clone of the write-queue skb), and `napi_consume_skb()` routes clones
to `__kfree_skb()` — the per-NAPI skb cache recycling does *not* apply
to them. Any gain therefore comes from batching the frees in poll
context (slab/cache locality of ~14 back-to-back frees per poll) and
from shortening `start_xmit` itself, not from skb-struct recycling.

A/B/A gate (same session, `iperf3 -R -t 30`, OTBR stopped, drift
control by re-flashing the baseline after):

| Set | Build | Reps | Median (Mbit/s) | Mean |
|---|---|---:|---:|---:|
| A1 baseline | #19 | 5 | 66.8 | 67.2 |
| B defer-frees | #21 | 10 | **67.4** | **67.9** |
| A2 baseline (re-flash) | #19 | 5 | 66.9 | — |

A1 ≈ A2 (no session drift), so the +0.55 Mbit/s median (+0.8 %) is
attributable to the change — **suggestive but not conclusive**
(t ≈ 1.7, p ≈ 0.11); B's central cluster (7/10 reps in 67.1–67.5)
sits consistently above A's (6/10 reps in 66.6–66.9). Correctness:
0 retrans across all 21 reps, every ring-anomaly counter 0, a 120 s
stress rep clean (67.6), no memory leak after 1.5 M packets
(MemFree −256 kB, slab noise), `tx_defer_queued` = 994 k / 1.58 M
packets (63 % — mechanism engaged), `tx_defer_direct` = 0 (cap never
hit). Two new ethtool counters (`tx_defer_queued`/`tx_defer_direct`,
28 → 30) stay as observability, per convention.

**Kept** — Track A-class profile (+1.2 % was kept on the same
protocol), modest measured payoff, zero measured risk, and it shortens
the latency-sensitive `start_xmit` path. Revisit at merge review if
the branch is squashed for release.

## v4.2.0 versioned I-MEM policies (2026-08-22)

Linux 6.18.45 and 7.1.9 were each profiled from an empty I-MEM window,
solved independently with the TX activity model, and rebuilt with local
text holes. Runtime-patch hosts are excluded rather than allowlisted. The
normal build reproduces and structurally verifies the exact point-release
policy before packaging.

The standard release bench used 11 runs per direction, with a fresh boot,
the radio and userland quiesced, no gateway access during a measurement,
and kernel/counter gates around the run:

| Kernel | TCP TX median | TCP RX median | Safety result |
|---|---:|---:|---|
| 6.18.45 | **82.8 Mbit/s** | **91.7 Mbit/s** | 0 retransmissions, 0 hard-counter failures, 0 relevant warnings |
| 7.1.9 | **82.8 Mbit/s** | **92.8 Mbit/s** | 0 retransmissions, 0 hard-counter failures, 0 relevant warnings |

Both clear the v4.2.0 operational fast-path thresholds (TX >= 80,
RX >= 90). The initial 6.18.45 qualification and the 7.1.9 run preceded
those absolute thresholds, so 7.1.9 remains an explicitly retrospective
qualification. The exact 6.18.45 image was rerun with the final harness on
2026-08-22, and the table reports that repeat. The measurements establish
that the shippable images meet the release objective with a large margin;
they do not estimate the exact I-MEM contribution or prove that one kernel
line outperforms the other.
