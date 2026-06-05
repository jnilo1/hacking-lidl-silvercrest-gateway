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
