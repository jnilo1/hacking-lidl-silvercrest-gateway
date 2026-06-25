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
likely amplifier. RX is already near the per-packet cache-flush
ceiling described below, so it does not see a similar lift.

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

## TX path per-packet decomposition (driver v2.4 + Track A, probe-on)

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

## Levers explored — orthogonal-levers session 2026-05-02

A dedicated measurement session evaluated four orthogonal levers
proposed by `BRIEF-tx-throughput-orthogonal-levers.md`.  See
`MEMO-tx-throughput-verdict.md` at the repo root for the full
per-track verdict; summary:

| Track                                          | Δ TCP TX | Verdict   |
|------------------------------------------------|---------:|-----------|
| A — `kick_tx` coalescing (N=4 + NAPI drain)    | +1.2 %   | Kept (v3.4.1) |
| B+ — TX flush writeback-only (skip invalidate) | −1.1 %   | Reverted  |
| C — NAPI weight 64 → 128                       | −0.9 %   | Reverted  |
| D — Full TX scatter-gather (`NETIF_F_SG`)      | −1.1 %   | Reverted  |

D is notable: the HW probe (`rtl8196e_ring_tx_sg_test`) confirmed the
switch ASIC honours mBuf `m_next` chains on TX, contradicting the
mbuf.h comment "MBUF_EOR is set only by ASIC" (true on RX only).  The
full SG path was implemented and runs correctly (99.96 % non-linear
SKBs once `NETIF_F_SG` is advertised) but splitting one big 1500 B
cache flush into N small flushes (head + frags) costs more than
skipping `skb_linearize` saves on this CPU.

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

## Linux 6.18 vs 7.1 — TCP TX A/B (7.1 bring-up, driver v2.14)

> Captured during 7.1 bring-up at driver v2.14. The 7.1 line now ships as a
> **supported** kernel in v4.0.0-rc2 (select it with `KERNEL=7.1`) and carries the
> same `rtl8196e-eth` **v2.15** as the 6.18 line — see `DESIGN.md`/`AUDIT.md` for the
> current driver state. The A/B below is kept as the bring-up record.

The 7.1 kernel line (`patches-7.1/` + `files-7.1/`, this overlay) carried the
**identical** `rtl8196e-eth` v2.14 driver as the 6.18 line at the time, so a same-box,
same-day A/B isolates the effect of the 6.18 → 7.1 *kernel* (TCP send-side,
NAPI, GRO, and 7.1's config defaults) on TCP TX, with the driver held constant.

Bench: `.88`, OTBR stopped, direct Cat-6 to the Gigabit host,
`iperf3 -c -R -t 30` (gateway → host = TX), 5-rep median; kernels swapped by
reflashing between phases.

| Kernel (driver v2.14)   | TX median (Mbit/s) | runs                                   |
|-------------------------|-------------------:|----------------------------------------|
| **7.1**                 | **~72.1**          | 71.8 (switch), 72.1 (direct, 71.3–74.3)|
| **6.18 (v4.0.0-rc1)**   | **~68.1**          | 68.4 (switch), 68.1 (direct, 68.1–70.1)|

**7.1 is ~+4 Mbit/s (~5–6 %) faster on TCP TX**, and the two 5-rep distributions
do not overlap (7.1 min 71.3 > 6.18 max 68.2 on the clean direct-cable runs). RX
is line-rate on both (≈94 Mbit/s), unchanged — as expected for the DMA-bound
receive path.

The gap is a real kernel-version effect, not a confound:

- **Same driver** (v2.14) on both lines, byte-for-byte.
- **Not a missing patch.** The rc1 TX-reclaim `timer_pending()` guard (whose
  absence otherwise drops TX ~5 % to the rc0 ≈67.6 level) was suspected missing
  from the prebuilt `kernel-6.18.img`; a clean from-source 6.18 rebuild with the
  guard verified present measured the *same* 68.1 — so ~68 is the genuine 6.18 TX
  here.
- **Not a link artifact.** Direct-cable 6.18 (~68.1) ≈ through-a-switch 6.18
  (68.4); the switch did not explain the 6.18 figure.

Caveat: this session ran ~2 Mbit/s below the documented 6.18 TX baseline (median
70.3, spread 69.3–72.8 — see the v2.14 gate above), i.e. the absolute numbers
were condition-depressed (host/thermal). The same-day A/B neutralises that: the
relative 7.1 > 6.18 gap is robust across three 6.18 and two 7.1 measurements.

_Measured 2026-06-17 on the `exp/kernel-7.1` branch. Flashes were loop-free
throughout (the bench bootloader carried the post-flash PHY-quiesce fix)._

## Standardized release bench — 7.1 (driver v2.15)

Release-gate health check run with the portable per-release harness
(`scripts/bench_release_iperf3.sh`: no ethtool, /proc-only counters,
inter-session medians). This is the **rc2 fix set ported to 7.1**: the eth
driver is now **v2.15** (carries ETHDRV-015, the poll-side RUNOUT-storm
resync for issue #99) and the box runs under the **V2.8 bootloader** whose
auto-boot PHY-quiesce fix makes the 7.1 warm-reboot / post-flash loop survive.

Target: `Linux zigbeegw 7.1.0-rtl8196e-v4.0.0-rc1 #3` on `.88`, OTBR stopped,
direct Cat-6 to the Gigabit host (`enp2s0`), iperf3 server on the gateway.
Inter-session: fresh server + fresh client per rep, 30 s TCP, 10 s gap, median.

| Workload                   | Reps | Median (Mbit/s) | Spread / loss          |
|----------------------------|:----:|----------------:|------------------------|
| TCP RX (host→gw)           | 3    | 93.9            | range 93.6–93.9        |
| **TCP TX (gw→host)**       | 10   | **69.5**        | spread 3.9, sd 1.36, range 69.0–72.9 |
| TCP stress (host→gw, 300s) | 1    | 93.8            | retrans 0.0000%        |
| UDP TX (gw→host, -b 0)     | 3    | 31.6            | loss 0.0%              |
| UDP RX (host→gw, -b 100M)  | 3    | 36.6            | loss 63.0% (line-rate flood) |

Counters (from `/proc`, no ethtool) over the TCP phase: rx_errs/rx_drop/
tx_errs/tx_drop all **+0**; TCP RetransSegs **+0** of +1.94 M segments
(0.0000 %). UDP flood drops happen on the host receiver, not on the gateway
(gw rx_drop/rx_errs +0). **Regression flags: PASS** on every threshold.

### On the TX gain — confirmed, but not by this protocol

The TCP TX median here (**~69.5**, range 69.0–72.9) sits squarely on top of the
6.18/rc2 standardized range — it does **not**, on its own, show the +4 Mbit/s
that the same-driver A/B above reports (7.1 ~72.1 vs 6.18 ~68.1). That is the
expected and self-consistent outcome, not a contradiction:

- The standardized bench is **inter-session** by design (each rep is a fresh
  invocation, spaced) so it is **cross-session-drift-dominated** (~3–4 Mbit/s
  here: sd 1.36, spread 3.9). A real +4 Mbit/s effect is the same size as the
  noise floor, so a single inter-session run cannot resolve it.
- The **paired, same-session A/B** above *can*: by reflashing 6.18↔7.1 on the
  same box the same day it cancels the drift, and there the two 5-rep
  distributions **do not overlap** (7.1 min 71.3 > 6.18 max 68.2). That is the
  authoritative measurement of the kernel-line TX delta.

So the 7.1 TX advantage is **real and confirmed (by the paired A/B)**, while the
standardized release bench is doing a different job — a portable, ethtool-free
health gate — and correctly reports 7.1 as **at parity-or-better with 6.18 and
within all thresholds**, with the cross-line delta below its resolution.

_Measured 2026-06-20 on the `exp/kernel-7.1` branch (driver v2.15, V2.8
bootloader). Flash-test the same day: cold boot clean and — unlike before V2.8 —
warm reboot now survives the 7.1 handoff._
